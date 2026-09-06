import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// The ONE quality every DISPLAY-ONLY JPEG in the pipeline is encoded at.
///
/// Display-only means: never written back to disk. Both consumers -- the
/// retained full-resolution payload (`payload_reencoder.dart`) and the 200px
/// sidebar tile (`sidebar_thumbnail_codec.dart`) -- feed pixels the user looks
/// at and nothing else; export re-reads the ORIGINAL file
/// (`photo_export_service.dart`) at its own, user-chosen quality.
///
/// USER RULING 2026-08-30: one constant, not two literals that happen to
/// match. The sidebar tile was 80 and is now 70; at a 200px resample the
/// difference is invisible, and the payload budget has to hold these bytes.
const int kDisplayJpegQuality = 70;

// --- WP5: persistent JPEG-encode worker pool -------------------------------
//
// `encodeJpegFromRgba` used to spawn one `Isolate.run` per call (170 spawns
// in 20.8s at the sidebar's rate -- allocation lens site #5). This section
// replaces the spawn-per-call body with a process-lifetime pool of `N`
// long-lived isolates behind the SAME exported function signature, so
// neither call site (the sidebar codec, the payload re-encoder) changes
// shape. The loop shape mirrors ceyx's `ceyxDecodeWorkerMain`
// (`decode_pool.dart:1114+`): one `ReceivePort`, a `ready` handshake, then a
// job loop until told to shut down.

const String _kJpegMsgReady = 'ready';
const String _kJpegMsgJob = 'job';
const String _kJpegMsgResult = 'result';
const String _kJpegMsgError = 'error';
const String _kJpegMsgShutdown = 'shutdown';

/// How many worker isolates the pure-Dart JPEG encoder has EVER spawned.
/// After warmup this must not grow per call -- 170 spawns in 20.8s is the
/// behaviour this counter exists to pin (allocation lens site #5).
@visibleForTesting
int debugJpegEncoderSpawnCount = 0;

class _JpegJob {
  _JpegJob(this.rgba, this.width, this.height, this.quality);
  final TransferableTypedData rgba;
  final int width;
  final int height;
  final int quality;
  int? requestId;
  final Completer<Uint8List> completer = Completer<Uint8List>();
}

class _JpegWorker {
  _JpegWorker(this.index);
  final int index;
  late final ReceivePort responses;
  Isolate? isolate;
  SendPort? sendPort;
  bool ready = false;
  bool dead = false;
  _JpegJob? currentJob;
}

/// Persistent pool backing [encodeJpegFromRgba]. Not exported; the public
/// surface stays exactly the one function plus [disposeJpegEncoderPool] for
/// test teardown.
class _JpegEncoderPool {
  _JpegEncoderPool({int width = 2}) : _width = width < 1 ? 1 : width;

  static const int maxRespawns = 8;
  final int _width;
  int _nextRequestId = 1;
  bool _disposed = false;
  bool _respawnCapped = false;
  int _respawnCount = 0;

  final List<_JpegWorker> _workers = [];
  final List<_JpegJob> _queue = [];
  final Map<int, _JpegJob> _byRequestId = {};

  Future<Uint8List> submit(
    Uint8List rgba, {
    required int width,
    required int height,
    required int quality,
  }) {
    if (_disposed) {
      return Future<Uint8List>.error(
        StateError('jpeg encoder pool disposed'),
      );
    }
    final job = _JpegJob(
      TransferableTypedData.fromList([rgba]),
      width,
      height,
      quality,
    );
    _queue.add(job);
    _pump();
    return job.completer.future;
  }

  void _pump() {
    while (_queue.isNotEmpty) {
      final worker = _idleReadyWorker();
      if (worker == null) {
        _maybeSpawn();
        return;
      }
      _dispatch(worker, _queue.removeAt(0));
    }
  }

  _JpegWorker? _idleReadyWorker() {
    for (final w in _workers) {
      if (w.ready && !w.dead && w.currentJob == null) return w;
    }
    return null;
  }

  void _maybeSpawn() {
    if (_respawnCapped) {
      _failQueuedForNoCapacity('respawn cap reached');
      return;
    }
    final live = _workers.where((w) => !w.dead).length;
    if (live >= _width) return;
    if (_workers.any((w) => !w.ready && !w.dead)) return;
    _spawn(_workers.length);
  }

  void _spawn(int index) {
    final worker = _JpegWorker(index);
    _workers.add(worker);
    worker.responses = ReceivePort('jpeg-encoder-pool-$index');
    worker.responses.listen((msg) => _onWorkerMessage(worker, msg));
    debugJpegEncoderSpawnCount++;
    Isolate.spawn(
          _jpegEncoderWorkerMain,
          worker.responses.sendPort,
          onExit: worker.responses.sendPort,
          onError: worker.responses.sendPort,
          errorsAreFatal: true,
          debugName: 'jpeg-encoder-$index',
        )
        .then((iso) {
          worker.isolate = iso;
          if (worker.dead) iso.kill(priority: Isolate.immediate);
        })
        .catchError((Object e) {
          _onWorkerLost(worker, 'spawn failed: $e');
        });
  }

  void _dispatch(_JpegWorker worker, _JpegJob job) {
    final id = _nextRequestId++;
    job.requestId = id;
    worker.currentJob = job;
    _byRequestId[id] = job;
    worker.sendPort!.send(<Object?>[
      _kJpegMsgJob,
      id,
      job.rgba,
      job.width,
      job.height,
      job.quality,
    ]);
  }

  void _onWorkerMessage(_JpegWorker worker, Object? raw) {
    if (raw == null) {
      _onWorkerLost(worker, 'worker isolate exited');
      return;
    }
    if (raw is! List || raw.isEmpty) {
      _onWorkerLost(worker, 'worker error: $raw');
      return;
    }
    final tag = raw[0];
    if (tag is! String) {
      _onWorkerLost(worker, 'worker error: $raw');
      return;
    }
    switch (tag) {
      case _kJpegMsgReady:
        worker.sendPort = raw[1] as SendPort;
        worker.ready = true;
        _pump();
        return;
      case _kJpegMsgResult:
        _completeJob(
          worker,
          raw[1] as int,
          raw[2] as TransferableTypedData,
          null,
        );
        return;
      case _kJpegMsgError:
        _completeJob(worker, raw[1] as int, null, raw.length > 2 ? raw[2] : null);
        return;
      default:
        _onWorkerLost(worker, 'unknown worker message: $tag');
        return;
    }
  }

  void _completeJob(
    _JpegWorker worker,
    int requestId,
    TransferableTypedData? payload,
    Object? error,
  ) {
    final job = _byRequestId.remove(requestId);
    worker.currentJob = null;
    if (job != null) {
      if (error != null) {
        job.completer.completeError(error);
      } else {
        job.completer.complete(payload!.materialize().asUint8List());
      }
    }
    _pump();
  }

  void _onWorkerLost(_JpegWorker worker, String detail) {
    if (worker.dead) return;
    worker.dead = true;
    worker.ready = false;
    final lost = worker.currentJob;
    worker.currentJob = null;
    _workers.remove(worker);
    worker.responses.close();

    if (lost != null) {
      _byRequestId.remove(lost.requestId);
      if (!lost.completer.isCompleted) {
        lost.completer.completeError(StateError('jpeg worker died: $detail'));
      }
    }

    if (_disposed) return;

    if (_respawnCount >= maxRespawns) {
      _respawnCapped = true;
      if (_workers.any((w) => !w.dead)) {
        _pump();
      } else {
        _failQueuedForNoCapacity('respawn cap reached, no worker left');
      }
      return;
    }
    _respawnCount++;
    _spawn(worker.index);
    _pump();
  }

  void _failQueuedForNoCapacity(String detail) {
    final stranded = List<_JpegJob>.from(_queue);
    _queue.clear();
    for (final job in stranded) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(StateError(detail));
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final worker in List<_JpegWorker>.from(_workers)) {
      worker.dead = true;
      try {
        worker.sendPort?.send(const <Object?>[_kJpegMsgShutdown]);
      } catch (_) {
        // Worker already gone; the kill below is the backstop.
      }
      worker.isolate?.kill(priority: Isolate.beforeNextEvent);
      worker.responses.close();
    }
    _workers.clear();
    final lost = List<_JpegJob>.from(_byRequestId.values)..addAll(_queue);
    _queue.clear();
    _byRequestId.clear();
    for (final job in lost) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(StateError('jpeg encoder pool disposed'));
      }
    }
  }
}

/// Worker entry point: receives jobs off its [ReceivePort] and JPEG-encodes
/// each one, until told to shut down. Loop shape copied from
/// `ceyxDecodeWorkerMain` (`decode_pool.dart:1114+`) -- this pool has no
/// native library to load, so there is no per-worker init step beyond the
/// ready handshake.
void _jpegEncoderWorkerMain(SendPort poolPort) {
  final jobs = ReceivePort('jpeg-encoder-worker');
  jobs.listen((Object? message) {
    if (message is! List || message.isEmpty) return;
    if (message[0] == _kJpegMsgShutdown) {
      jobs.close();
      return;
    }
    if (message[0] != _kJpegMsgJob) return;
    final requestId = message[1] as int;
    final transfer = message[2] as TransferableTypedData;
    final width = message[3] as int;
    final height = message[4] as int;
    final quality = message[5] as int;
    try {
      final rgba = transfer.materialize().asUint8List();
      final image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgba.buffer,
        bytesOffset: rgba.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      final encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
      poolPort.send(<Object?>[
        _kJpegMsgResult,
        requestId,
        TransferableTypedData.fromList([encoded]),
      ]);
    } catch (e) {
      poolPort.send(<Object?>[_kJpegMsgError, requestId, '$e']);
    }
  });
  poolPort.send(<Object?>[_kJpegMsgReady, jobs.sendPort]);
}

_JpegEncoderPool? _sharedJpegEncoderPool;

_JpegEncoderPool _pool() => _sharedJpegEncoderPool ??= _JpegEncoderPool();

/// Test-only: shuts the shared pool down and clears it, so tests do not leak
/// isolates across files. Safe to call even when no pool has been created
/// yet.
@visibleForTesting
Future<void> disposeJpegEncoderPool() async {
  final pool = _sharedJpegEncoderPool;
  _sharedJpegEncoderPool = null;
  if (pool != null) await pool.dispose();
}

/// Wraps RGBA8 [rgba] in an [img.Image] and JPEG-encodes it on a persistent
/// worker isolate. `numChannels: 4` + [img.ChannelOrder.rgba] match `dart:ui`'s
/// `rawRgba` byte order exactly, so no channel shuffle happens here; the
/// encoder drops alpha, which JPEG cannot represent.
///
/// WP5: dispatched to a process-lifetime pool of worker isolates instead of
/// spawning one `Isolate.run` per call -- the sidebar thumbnail codec calls
/// this once per tile, and per-call spawn was 170 spawns in 20.8s
/// (allocation lens site #5). This is the ONE encoder in the pipeline: the
/// sidebar thumbnail codec and the Phase 13 payload re-encoder both call it,
/// so their channel-order and isolate decisions cannot drift apart.
///
/// Throws whatever the encoder throws. Callers own the fallback policy.
Future<Uint8List> encodeJpegFromRgba(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) {
  return _pool().submit(rgba, width: width, height: height, quality: quality);
}
