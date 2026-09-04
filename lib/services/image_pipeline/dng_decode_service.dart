import 'package:ceyx/ceyx.dart';
import 'package:flutter/foundation.dart';

import '../../perf/perf_log.dart';
import 'dng_decode_contract.dart';

/// P2: routes the [DngFullDecoder] seam through ceyx's persistent worker pool
/// instead of an `Isolate.run` per decode.
///
/// What changed and what did NOT:
/// * changed — one dylib load per WORKER for the process lifetime, instead of
///   one per decode, and no isolate spawn on the browse path after warmup;
/// * unchanged — the seam's signature, the `TransferableTypedData` return
///   path, and the "any throw ⇒ fall back to the old path" contract. Every
///   existing fake decoder in the test suite is untouched by this file.
///
/// Kept production-clean: no dylib-preload workaround, no dev-only path
/// hacks. The dylib lands in `<App>.app/Contents/Frameworks/` because
/// `ceyx` is a Flutter FFI plugin whose pod vendors it, and
/// `dng_bindings.dart`'s own search order finds it there.
/// Raw value of the pool kill-switch define. Empty when not supplied.
const String kDecodePoolDefine = String.fromEnvironment(
  'HALCYON_DECODE_POOL',
);

/// Whether [decodeDngFull] uses the worker pool. Compile-time const, so the
/// unused arm is tree-shaken from a release build.
///
/// `--dart-define=HALCYON_DECODE_POOL=0` (or `false`) reverts this seam to the
/// pre-pool `Isolate.run`-per-decode path, so the SAME tree can be captured
/// both ways. That is the only A/B that controls for every other change in a
/// round; a headless bench cannot.
/// Deliberately NOT `bool.fromEnvironment`: that returns its default for any
/// value other than the exact strings `true`/`false`, so the documented `=0`
/// spelling would silently leave the pool ON — a kill-switch that looks set
/// and does nothing is worse than no kill-switch at all.
///
/// Written inline rather than via [decodePoolEnabledFor] because Dart forbids
/// method invocation in a const expression, and this MUST stay const to be
/// tree-shakable. TC-944 asserts the two spellings agree, so they cannot
/// drift apart.
const bool kDecodePoolEnabled =
    kDecodePoolDefine != '0' &&
    kDecodePoolDefine != 'false' &&
    kDecodePoolDefine != 'off';

/// The same rule as [kDecodePoolEnabled], callable so it can be tested for
/// every spelling instead of only the one this build was compiled with.
bool decodePoolEnabledFor(String raw) =>
    raw != '0' && raw != 'false' && raw != 'off';

Future<DecodedRgba> decodeDngFull(String path) async {
  _ensurePoolLogger();
  final image = kDecodePoolEnabled
      ? await CeyxDecodePool.shared.decode(path)
      // LEGACY ARM: one isolate spawn + one dylib load per decode. Kept
      // reachable ONLY through the define above, for same-tree A/B captures.
      : await DngDecoderService().decodeOnWorker(path);

  final expectedLength = image.width * image.height * 4;
  if (image.rgbaData.length != expectedLength) {
    throw StateError(
      'ceyx returned rgbaData.length=${image.rgbaData.length} '
      'but width*height*4=$expectedLength (width=${image.width}, '
      'height=${image.height})',
    );
  }

  return DecodedRgba(
    rgba: image.rgbaData,
    width: image.width,
    height: image.height,
  );
}

/// Single obvious entry point for the pipe squad to wire into
/// `image_preload_controller.dart`.
const DngFullDecoder halcyonDngFullDecoder = decodeDngFull;

bool _poolLoggerInstalled = false;

/// Routes pool events (ready / worker died / respawn / narrowing) into the
/// perf log AND onto the console. A silently narrowed pool is exactly the
/// defect class this loudness exists to prevent, so it is deliberately not
/// gated on `PerfLog.enabled`.
void _ensurePoolLogger() {
  if (_poolLoggerInstalled) return;
  _poolLoggerInstalled = true;
  CeyxDecodePool.logger = (line) {
    PerfLog.log(line);
    debugPrint('[ceyx-pool] $line');
  };
}

/// Pushes the user's decode-lane width onto the pool, so N persistent workers
/// tracks the runtime setting (default 2; the user stress-tests at 5).
///
/// Growing spawns lazily on the next admission; narrowing never pre-empts an
/// in-flight native decode — surplus workers leave after their current job.
/// That is the same rule `DecodeLane.width` already follows, so the two
/// bounds can never disagree about what is admissible.
/// Supersedes every in-flight decode (folder switch).
///
/// This is soft cancellation and nothing else: no native decode is
/// cancellable, so the running work finishes and its RESULT is dropped at the
/// pool boundary — without materialising the ~20MB payload, which is the
/// expensive half. The consumer-side folder gate in
/// `ImagePreloadController._completeOutcome` is the other half: it refuses the
/// resulting throw, so a superseded decode can never write a permanent-miss
/// latch into the newly opened folder's state.
void bumpHalcyonDecodePoolGeneration() {
  _ensurePoolLogger();
  CeyxDecodePool.shared.bumpGeneration();
}

void setHalcyonDecodePoolWidth(int width) {
  _ensurePoolLogger();
  CeyxDecodePool.shared.width = width;
}
