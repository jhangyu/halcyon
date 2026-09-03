import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// How the pacer asks to be woken once per frame. Injected so every test is
/// deterministic and no assertion depends on wall-clock timing.
typedef FrameHook = void Function(VoidCallback callback);

/// Paces publication into Flutter's own pipeline: at most [perFrame]
/// `ImageCache` registrations or GPU uploads per frame, nearest-first, with
/// the selected item exempt.
///
/// The pipeline had no notion of a frame budget anywhere: `_precacheTierOneWindow`
/// walks the whole retention window in one synchronous loop on every navigation
/// pass, so codec-completion and upload work arrive as one clump behind a
/// single navigation event.
///
/// This class knows nothing about images. It holds closures and a rank; the
/// caller decides what a publication IS and what makes one stale.
class PublicationPacer {
  PublicationPacer({
    FrameHook? scheduleFrameCallback,
    int perFrame = 1,
    int maxQueued = 4,
  })  : _frameHook = scheduleFrameCallback,
        _perFrame = perFrame < 1 ? 1 : perFrame,
        _maxQueued = maxQueued < 1 ? 1 : maxQueued;

  final FrameHook? _frameHook;
  final int _perFrame;
  final int _maxQueued;

  final Map<String, _Entry> _queued = <String, _Entry>{};
  int _seq = 0;
  bool _armed = false;

  int get queuedCount => _queued.length;

  /// Submits one publication.
  ///
  /// [exempt] publishes SYNCHRONOUSLY, in this turn: the item the user is
  /// looking at must never wait a frame for its own pixels (the same rationale
  /// as `kFullResPriorityBase`'s "blank slots the user can SEE go first").
  ///
  /// [stillValid] is the load-bearing check and is evaluated at DRAIN time, not
  /// here (G-023): between submit and drain the payload may have been replaced
  /// or the id may have left the window, and publishing then would build a
  /// provider for a payload that is no longer current -- a silent double
  /// decode, per invariant I1.
  ///
  /// [discard] releases whatever the entry was holding (e.g. a `ui.Image`) when
  /// it is dropped instead of published. It runs exactly once per dropped
  /// entry and never for a published one.
  void submit({
    required String id,
    required int rank,
    required bool exempt,
    required bool Function() stillValid,
    required void Function() publish,
    void Function()? discard,
  }) {
    if (exempt) {
      if (stillValid()) {
        publish();
      } else {
        discard?.call();
      }
      return;
    }
    // A re-submission supersedes the queued entry: the old one's holdings must
    // be released or they leak.
    _queued.remove(id)?.discard?.call();
    _queued[id] = _Entry(
      rank: rank,
      seq: _seq++,
      stillValid: stillValid,
      publish: publish,
      discard: discard,
    );
    _enforceCapacity();
    _arm();
  }

  /// Drops every queued entry, releasing what each holds.
  void clear() {
    for (final entry in _queued.values) {
      entry.discard?.call();
    }
    _queued.clear();
  }

  @visibleForTesting
  void drainOnce() => _drain();

  void _enforceCapacity() {
    while (_queued.length > _maxQueued) {
      // Farthest from the selection loses, mirroring the beyond-band-first
      // eviction rule. That may be the entry just submitted.
      String? worstId;
      _Entry? worst;
      _queued.forEach((id, entry) {
        if (worst == null ||
            entry.rank > worst!.rank ||
            (entry.rank == worst!.rank && entry.seq < worst!.seq)) {
          worstId = id;
          worst = entry;
        }
      });
      _queued.remove(worstId)?.discard?.call();
    }
  }

  void _arm() {
    if (_armed || _queued.isEmpty) return;
    _armed = true;
    final hook = _frameHook;
    if (hook != null) {
      hook(_drain);
      return;
    }
    // Resolved lazily so constructing a pacer before the binding exists is
    // harmless. `addPostFrameCallback` alone only fires when SOMETHING ELSE
    // schedules a frame; on an idle app (nothing pumping the scheduler) a
    // queued registration can stall indefinitely. `scheduleFrame()` requests
    // the frame this pacer itself needs to drain.
    SchedulerBinding.instance.addPostFrameCallback((_) => _drain());
    SchedulerBinding.instance.scheduleFrame();
  }

  void _drain() {
    _armed = false;
    var budget = _perFrame;
    while (budget > 0 && _queued.isNotEmpty) {
      final id = _nearestId()!;
      final entry = _queued.remove(id)!;
      if (!entry.stillValid()) {
        // A dropped stale entry does NOT consume the frame's budget: it did no
        // work, so charging for it would starve a valid entry behind it.
        entry.discard?.call();
        continue;
      }
      entry.publish();
      budget--;
    }
    _arm();
  }

  String? _nearestId() {
    String? bestId;
    _Entry? best;
    _queued.forEach((id, entry) {
      if (best == null ||
          entry.rank < best!.rank ||
          (entry.rank == best!.rank && entry.seq < best!.seq)) {
        bestId = id;
        best = entry;
      }
    });
    return bestId;
  }
}

class _Entry {
  _Entry({
    required this.rank,
    required this.seq,
    required this.stillValid,
    required this.publish,
    required this.discard,
  });

  final int rank;
  final int seq;
  final bool Function() stillValid;
  final void Function() publish;
  final void Function()? discard;
}
