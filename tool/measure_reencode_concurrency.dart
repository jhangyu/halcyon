// T10.4 (R-H): locates the binding constraint on background re-encode
// concurrency. MEASUREMENT ONLY -- this file changes no production behaviour
// and no production constant. See docs/logs/2026-09-19/t10-4-prereg.txt for
// the pre-registered read rules, which were written before this file existed.
//
// INVOCATION (corrected from the plan's `dart run`, see prereg C-1):
//
//   flutter test tool/measure_reencode_concurrency.dart
//
// The subject is `ImagePreloadController`, which imports package:flutter and
// needs a binding, so a plain `dart run` entry point cannot host it. This is
// the same shape `tool/decode_worker_bench/mem8_probe_test.dart` uses.
//
// WHAT IT MEASURES: which admission gate bounds the number of background
// (deferred full-size) re-encodes running at once. Admission is decided
// before any pixel is read, so the production controller is driven with fakes
// at its OWN injection seams (`deferredEncodeDecoder`, `payloadEncoder`) with
// a fixed artificial dwell, rather than with a RAW corpus. It measures
// SCHEDULING STRUCTURE -- not throughput, not wall time, not memory.
//
// Emits, per configuration:
//   T104|RUN <name> width=<n> budget_bytes=<n> ...
//   T104|SAMPLE <name> t_ms=<n> active=<n> inflight_bytes=<n> encode_running=<n>
//   T104|SUMMARY <name> width=<n> budget_bytes=<n> supply=<n>
//                peak_reencodes=<n> inflight_at_peak=<n> encode_running_max=<n>
//                completed=<n> abandoned=<n> verdict=<GATE-LIMITED|SUPPLY-LIMITED|VOID>
// This harness reads the controller's `debug*` gauges, which are
// `@visibleForTesting`. It IS test-shaped code (it runs under `flutter test`)
// but it lives under `tool/` by the plan's file contract, and the analyzer's
// allowance is path-based. Suppressed file-wide, with the reason stated,
// rather than by relaxing the annotation in `lib/` -- this task changes no
// production file.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/frame_bytes.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

/// Every item is a RAW with no embedded preview, so every slot takes the
/// decode path.
Future<NativeImageResult> _needsRawDecodeLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _frame(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

/// The INLINE decode's frame size. Its re-encode is refused by the harness
/// encoder (see [_Harness._encode]), which is what leaves the slot holding a
/// temporary `PixelPayload` and schedules the background job.
const int _inlineWidth = 60;
const int _inlineHeight = 40;

/// The BACKGROUND job's frame size -- deliberately different from the inline
/// one so the single `PayloadEncoder` seam can tell the two encodes apart by
/// argument alone, with no flag and no call counter.
const int _deferredWidth = 64;
const int _deferredHeight = 48;

/// How long a background decode pretends to take. Long enough that overlap is
/// observable at millisecond resolution; short enough that a 24-item burst
/// finishes inside a test timeout.
const Duration _deferredDecodeDwell = Duration(milliseconds: 60);

/// How long the background encode pretends to take.
const Duration _deferredEncodeDwell = Duration(milliseconds: 10);

const int _itemCount = 24;

List<PhotoItem> _rawItems(int count) => [
  for (var i = 0; i < count; i++)
    PhotoItem(id: 'p${i.toString().padLeft(2, '0')}', files: [
      File('/tmp/p$i.dng'),
    ]),
];

class _Result {
  _Result({
    required this.name,
    required this.width,
    required this.budgetBytes,
    required this.supply,
    required this.peak,
    required this.inflightAtPeak,
    required this.encodeRunningMax,
    required this.completed,
    required this.abandoned,
  });

  final String name;
  final int width;
  final int budgetBytes;
  final int supply;
  final int peak;
  final int inflightAtPeak;
  final int encodeRunningMax;
  final int completed;
  final int abandoned;

  /// VOID beats every other verdict: a run that never overlapped measured the
  /// harness, not the system (pre-registered rule F).
  String get verdict {
    if (peak < 2) return 'VOID(peak<2)';
    if (supply > 0 && peak >= supply) return 'SUPPLY-LIMITED';
    return 'GATE-LIMITED';
  }

  String get summary =>
      'T104|SUMMARY $name width=$width budget_bytes=$budgetBytes '
      'supply=$supply peak_reencodes=$peak inflight_at_peak=$inflightAtPeak '
      'encode_running_max=$encodeRunningMax completed=$completed '
      'abandoned=$abandoned verdict=$verdict';
}

class _Harness {
  _Harness({required this.name, required this.width, required this.budgetBytes});

  final String name;
  final int width;
  final int budgetBytes;

  final Stopwatch _clock = Stopwatch()..start();

  /// Background re-encodes currently inside their decode phase.
  int _active = 0;

  /// O1. Peak of [_active].
  int _peak = 0;

  /// O2, sampled at the instant [_peak] was set.
  int _inflightAtPeak = 0;

  /// O3.
  int _encodeRunningMax = 0;

  /// SUPPLY: one per refused inline encode, i.e. one per background job the
  /// controller will schedule.
  int _supply = 0;

  ImagePreloadController? _controller;

  void _sample(String why) {
    final controller = _controller;
    final inflight = controller?.debugInflightBytes ?? 0;
    final encodeRunning = controller?.debugEncodeStageRunningCount ?? 0;
    if (encodeRunning > _encodeRunningMax) _encodeRunningMax = encodeRunning;
    if (_active > _peak) {
      _peak = _active;
      _inflightAtPeak = inflight;
    }
    stdout.writeln(
      'T104|SAMPLE $name t_ms=${_clock.elapsedMilliseconds} why=$why '
      'active=$_active inflight_bytes=$inflight '
      'encode_running=$encodeRunning',
    );
  }

  Future<DecodedRgba> _inlineDecode(String path) async =>
      _frame(_inlineWidth, _inlineHeight);

  /// The BACKGROUND decode. Its enter/exit brackets are where O1 is counted.
  Future<DecodedRgba> _deferredDecode(String path) async {
    _active++;
    _sample('deferred_decode_enter');
    await Future<void>.delayed(_deferredDecodeDwell);
    final frame = _frame(_deferredWidth, _deferredHeight);
    _active--;
    _sample('deferred_decode_exit');
    return frame;
  }

  Future<Uint8List> _encode(
    Uint8List rgba, {
    required int width,
    required int height,
    required int quality,
  }) async {
    if (width == _deferredWidth && height == _deferredHeight) {
      await Future<void>.delayed(_deferredEncodeDwell);
      return Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]);
    }
    // The inline re-encode. Refusing it is what makes the slot keep a
    // temporary PixelPayload and acquire a background job -- the exact
    // situation TC-1232 pins.
    _supply++;
    throw StateError('inline encode refused by the T10.4 harness');
  }

  Future<_Result> run() async {
    final controller = ImagePreloadController(
      imageLoader: _needsRawDecodeLoader,
      dngDecoder: _inlineDecode,
      deferredEncodeDecoder: () => _deferredDecode,
      payloadEncoder: _encode,
      decodeLaneWidth: width,
      inflightByteBudget: budgetBytes,
      // Harness ARGUMENT, not a production constant: retention floor (-3..+5)
      // would cap the number of simultaneously schedulable background jobs
      // below the widest lane setting and turn a supply limit into a false
      // "the gate binds at 8" reading. See prereg section G.
      retention: const RetentionPolicy(
        before: _itemCount,
        after: _itemCount,
        payloadByteBudget: 256 * 1024 * 1024,
      ),
    );
    _controller = controller;
    controller.updateTargetSize(320, 240);

    final items = _rawItems(_itemCount);
    stdout.writeln(
      'T104|RUN $name width=$width budget_bytes=$budgetBytes '
      'items=$_itemCount deferred_decode_dwell_ms='
      '${_deferredDecodeDwell.inMilliseconds} '
      'encode_stage_width=${controller.debugEncodeStageWidth}',
    );

    unawaited(
      controller.preloadImages(
        items: items,
        selectedItemId: items.first.id,
        notifyLoaded: () {},
      ),
    );

    // Poll until the background work stops moving. No fixed sleep: the exit
    // condition is "two consecutive quiet polls after at least one job
    // finished", with a hard ceiling so a wedged run fails loudly instead of
    // hanging.
    var quiet = 0;
    var lastDone = -1;
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      _sample('poll');
      final done = controller.debugDeferredCompletedCount +
          controller.debugDeferredAbandonedCount;
      if (done == lastDone && _active == 0 && done > 0) {
        quiet++;
        if (quiet >= 4) break;
      } else {
        quiet = 0;
      }
      lastDone = done;
    }

    final result = _Result(
      name: name,
      width: width,
      budgetBytes: budgetBytes,
      supply: _supply,
      peak: _peak,
      inflightAtPeak: _inflightAtPeak,
      encodeRunningMax: _encodeRunningMax,
      completed: controller.debugDeferredCompletedCount,
      abandoned: controller.debugDeferredAbandonedCount,
    );
    controller.dispose();
    _controller = null;
    return result;
  }
}

void main() {
  late ImageCache imageCache;
  late int originalMaximumSizeBytes;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    imageCache = PaintingBinding.instance.imageCache;
    originalMaximumSizeBytes = imageCache.maximumSizeBytes;
    imageCache.maximumSizeBytes = 256 << 20;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    imageCache.maximumSizeBytes = originalMaximumSizeBytes;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  test('T10.4 background re-encode concurrency', () async {
    // The four PRE-REGISTERED configurations (prereg section E). R1's budget
    // is the production derivation at width 8; R2 halves it; R3 moves width
    // alone; R4 gives the byte gate its strongest possible chance.
    final fullBudget = decodeInflightByteBudget(decodeLaneWidth: 8);
    final configs = <_Harness>[
      _Harness(name: 'R1', width: 8, budgetBytes: fullBudget),
      _Harness(name: 'R2', width: 8, budgetBytes: fullBudget ~/ 2),
      _Harness(name: 'R3', width: 2, budgetBytes: fullBudget),
      _Harness(name: 'R4', width: 8, budgetBytes: 1),
    ];

    final results = <_Result>[];
    for (final config in configs) {
      results.add(await config.run());
    }
    stdout.writeln('T104|--- SUMMARIES ---');
    for (final result in results) {
      stdout.writeln(result.summary);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
