import 'package:ceyx/ceyx.dart';
import 'package:flutter/foundation.dart';

import '../../perf/perf_log.dart';
import '../platform/working_set_trim.dart';
import 'dng_decode_contract.dart';

/// P2: routes the [DngFullDecoder] seam through ceyx's persistent worker pool
/// instead of an `Isolate.run` per decode.
///
/// What changed and what did NOT:
/// * changed — one dylib load per WORKER for the process lifetime, instead of
///   one per decode, and no isolate spawn on the browse path after warmup;
/// * changed (H2-A) — the pool arm's decode payload crosses the isolate
///   boundary as a native POINTER plus dimensions, not as a
///   `TransferableTypedData` copy. `image.rgbaData` is therefore a zero-copy
///   view over native memory whose lifetime is bound to that typed list by a
///   `NativeFinalizer` inside ceyx's pool; the ~97MB never enters the Dart
///   heap. Nothing here changes: the length check and [DecodedRgba]
///   construction below are backing-store-agnostic. The LEGACY arm at :57-58
///   still returns `TransferableTypedData`-materialised bytes — it is the A/B
///   control and is deliberately left alone;
/// * unchanged — the seam's signature and the "any throw ⇒ fall back to the
///   old path" contract. Every existing fake decoder in the test suite is
///   untouched by this file.
///
/// Kept production-clean: no dylib-preload workaround, no dev-only path
/// hacks. The dylib lands in `<App>.app/Contents/Frameworks/` because
/// `ceyx` is a Flutter FFI plugin whose pod vendors it, and
/// `dng_bindings.dart`'s own search order finds it there.
Future<DecodedRgba> decodeDngFull(String path) async {
  ensureHalcyonDecodePoolConfigured();
  final image = await CeyxDecodePool.shared.decode(path);

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
    // R2b (gc-remediation): `image.nativeAddress` is 0 on the legacy
    // TransferableTypedData arm (`DngDecoderService().decodeOnWorker`), so
    // `nativeKeepAlive` is harmless to set unconditionally -- a zero address
    // makes every downstream pointer-path gate refuse regardless of what
    // this field holds.
    nativeAddress: image.nativeAddress,
    nativeKeepAlive: image,
    // WP6 (gc-remediation): end-of-consumption pool return. Safe on BOTH arms
    // -- `DngImage.releaseToPool` is idempotent and a documented no-op when no
    // pooled buffer backs this image, which is exactly the legacy arm's case.
    releaseNative: image.releaseToPool,
  );
}

/// Single obvious entry point for the pipe squad to wire into
/// `image_preload_controller.dart`.
const DngFullDecoder halcyonDngFullDecoder = decodeDngFull;

/// Task 8 (native-rotation-spec, round 3) production binding for
/// [DngOrientingFullDecoder]. The pinned ceyx package now carries the pool's
/// `decode(path, exifOrientation: ...)` entry (Tasks 3-4, committed) and
/// self-reports what it actually applied on [DngImage.appliedOrientation] --
/// this function is a plain pass-through of that report, not a decision
/// point: Halcyon never assumes "I asked for orientation, therefore it
/// happened" (spec §1.4). The mapping degrades exactly like every other arm
/// in this file:
///
/// * **pool arm with an old dylib** -- `CeyxDecodePool.decode` still accepts
///   `exifOrientation` (it is a Dart-side parameter, always present since
///   Task 4), but the ceyx service's own self-verifying consistency check
///   (`dng_decoder_service.dart:selfVerifiedAppliedOrientation`) reports
///   `appliedOrientation: 1` whenever the native call could not have applied
///   it (missing symbol, or a transposing request whose returned extent did
///   not swap). Nothing here needs to re-check that: [DngImage] already did.
/// * **pool arm with the new dylib** -- `appliedOrientation` mirrors what the
///   decoder actually did, and the residual collapses to identity for the RAW
///   route (spec §1.4), which is what lets `photo_source.dart:615`'s
///   `usePointer` gate flip to true with zero edits to that line.
Future<DecodedRgba> decodeDngFullOriented(
  String path, {
  required int exifOrientation,
}) async {
  ensureHalcyonDecodePoolConfigured();
  final image = await CeyxDecodePool.shared.decode(
    path,
    exifOrientation: exifOrientation,
  );

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
    nativeAddress: image.nativeAddress,
    nativeKeepAlive: image,
    releaseNative: image.releaseToPool,
    appliedOrientation: image.appliedOrientation,
  );
}

const DngOrientingFullDecoder halcyonOrientingDngFullDecoder =
    decodeDngFullOriented;

bool _poolConfigured = false;

/// One-time process configuration of the ceyx decode pool. Idempotent; called
/// from every entry point below, so no startup ordering has to be maintained.
///
/// Does three things:
///
/// 1. **Re-asserts the native buffer pool (R6, Task #9, user ruling
///    2026-09-06; updated by S2 2026-09-11).** `CeyxDecodePool.nativeBufferPool`
///    is now a NON-NULLABLE static defaulting to `CeyxNativeBufferPool.shared`
///    (decision D2), so this store no longer switches the pooled route on — the
///    ceyx package does that itself, and the pooled-route gate
///    (`decode_pool.dart`, `_pooledRouteEnabled`) asks only whether the dylib
///    exports the decode-into entry pair. Historically the ceyx default WAS
///    null and every gate short-circuited on it, so until this assignment
///    existed the whole WP6/WP10 decode-into route was reachable only from
///    ceyx's own tests while production leaked through the self-allocating
///    path. What the store buys TODAY is narrower but still real: the field is
///    mutable, so a test helper that swapped in a small or instrumented pool
///    cannot leave production running on it.
///
/// 2. **Installs the shrink→trim hook.** See [WorkingSetTrim.onPoolShrink]:
///    the working-set trim is coupled to pool SHRINK COMPLETION, never to
///    idleness — an idle-coupled trim pages out exactly the idle pooled slots
///    the pool keeps resident for immediate reuse, while after a shrink those
///    slots are already freed and returning their pages is unambiguously
///    right. The folder-switch trim (`trimNow`, `AppState.loadFolder`) is
///    unchanged.
///
/// 3. **Routes pool events into the perf log and the console.** A silently
///    narrowed pool is exactly the defect class this loudness exists to
///    prevent, so it is deliberately not gated on `PerfLog.enabled`.
void ensureHalcyonDecodePoolConfigured() {
  // RE-ASSERTED on every call, deliberately NOT behind the latch below. These
  // two are process invariants held in mutable statics that other code (and
  // any test helper) can clear; two stores are free, whereas a latched
  // assignment that something else resets afterwards leaves the pooled route
  // silently off — which is the exact failure this whole task exists to fix.
  // The latch guards only the closure allocations, which is all it was ever
  // for.
  CeyxDecodePool.nativeBufferPool = CeyxNativeBufferPool.shared;
  // A top-level function reference, not a closure literal: repeated assignment
  // is then identity-stable, so re-asserting it outside the latch cannot
  // accumulate distinct closures.
  CeyxNativeBufferPool.shared.onShrink = _trimAfterPoolShrink;

  if (_poolConfigured) return;
  _poolConfigured = true;
  CeyxDecodePool.logger = (line) {
    PerfLog.log(line);
    debugPrint('[ceyx-pool] $line');
  };
  // H2 discriminator: time the main-isolate materialize step only while the
  // perf log is actually recording, so a non-capture run pays one function
  // call per job and nothing else. The emitted `pool.materialize|...` line
  // reaches the PERF| file through the logger wired above.
  CeyxDecodePool.materializeTimingEnabled = () => PerfLog.enabled;
}

/// The pool's shrink-completion listener: a completed shrink has just freed
/// pooled slots, so this is the moment to hand their pages back to the OS.
/// The freed count is informational only — the trim is unconditional.
void _trimAfterPoolShrink(int freedBuffers) => WorkingSetTrim.onPoolShrink();

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
  ensureHalcyonDecodePoolConfigured();
  CeyxDecodePool.shared.bumpGeneration();
}

/// Test seam for [halcyonDecodeWidthRecommendations]. When non-null it is used
/// instead of the live pool, so widget tests can render the settings panel
/// without spawning a decode worker or loading the dylib.
@visibleForTesting
List<int>? Function()? debugDecodeWidthRecommendationsOverride;

/// R4 item 1 / ruling r-6. This machine's ADVISORY recommended decode widths
/// for the 24 MP / 61 MP / 108 MP classes, or null when no decode worker has
/// reported yet (or the pinned dylib predates the query).
///
/// FOR DISPLAY ONLY — nothing clamps the user's lane width against these.
List<int>? halcyonDecodeWidthRecommendations() {
  final override = debugDecodeWidthRecommendationsOverride;
  if (override != null) return override();
  return CeyxDecodePool.shared.nativeRecommendations;
}

/// R4 item 1: this same assignment now ALSO configures the ceyx native slot
/// cap. `CeyxDecodePool.width` broadcasts the value to its workers, which call
/// the native configure entry in this same process against the process-global
/// slot pool. Before this the setting reached the Dart pool only, so a user
/// asking for 8 lanes got 8 isolates contending for a hardcoded 4 native
/// slots — the narrower number silently governed.
///
/// Ruling r-6: the user's value is pushed through unmodified. Nothing here
/// clamps it against the machine's recommended width; that recommendation is
/// displayed in settings and is advisory only.
void setHalcyonDecodePoolWidth(int width) {
  ensureHalcyonDecodePoolConfigured();
  CeyxDecodePool.shared.width = width;
  // Requested, not effective: the effective value arrives asynchronously as a
  // worker ack and is logged by the pool logger installed above. Logging both
  // is what makes a divergence visible instead of silent.
  PerfLog.log('lane.native_slots|requested=$width');
}
