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
  ensureHalcyonDecodePoolConfigured();
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
/// * **legacy arm** (`kDecodePoolEnabled == false`) has no oriented decode at
///   all -- it calls the existing unoriented worker-isolate path and reports
///   `appliedOrientation: 1`, so the host applies the FULL declared
///   orientation via the residual, byte-identical to today.
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
  final image = kDecodePoolEnabled
      ? await CeyxDecodePool.shared.decode(path, exifOrientation: exifOrientation)
      // LEGACY ARM: no oriented decode entry exists on this path at all --
      // reachable only through the `HALCYON_DECODE_POOL` kill-switch define,
      // same as decodeDngFull's own legacy arm above.
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
/// 1. **Wires the native buffer pool (R6, Task #9, user ruling 2026-09-06).**
///    `CeyxDecodePool.nativeBufferPool` defaults to null in the ceyx package,
///    and every pooled-route gate short-circuits on that null
///    (`decode_pool.dart:532-535`). Until this assignment existed the whole
///    WP6/WP10 decode-into route was reachable only from ceyx's own tests:
///    production decodes fell back to the legacy native allocator, and nothing
///    was red anywhere — the route was shipped, tested, and carrying zero
///    traffic. The assignment lives HERE rather than as a default inside ceyx
///    because a library must not decide on its own to hold eight ~100MB
///    resident slots for every consumer; the host app owns that budget.
///
/// 2. **Suppresses the idle working-set trim.** See
///    [WorkingSetTrim.suppressed]: idle trimming pages out exactly the idle
///    pooled slots the pool keeps resident for immediate reuse. The
///    folder-switch trim (`trimNow`) is deliberately left enabled.
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
  WorkingSetTrim.suppressed = true;

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
