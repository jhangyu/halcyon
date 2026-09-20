import 'package:ceyx/ceyx.dart';
import 'package:flutter/foundation.dart';

import '../../perf/perf_log.dart';
import '../platform/working_set_trim.dart';
import 'dng_decode_contract.dart';

/// The output format EVERY RAW/DNG decode path requests (mem8 T15a step 2,
/// R-A/R-L). ONE constant, referenced by every call site, so "is there a
/// format branch anywhere?" is answerable by grep rather than by reading.
///
/// ceyx keeps rgba8 as ITS default for other consumers (R-B); Halcyon
/// overrides on its own side. There is deliberately NO per-path exemption —
/// not even for the 200 px sidebar thumbnail, whose per-tile conversion cost
/// is a knowingly accepted trade (R-L). Uniformity is the design: one
/// exemption reintroduces the mixed-format lane problem R-D made moot.
const CeyxOutputFormat kHalcyonDecodeOutputFormat = CeyxOutputFormat.yuv420;

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
  final image = await CeyxDecodePool.shared.decode(
    path,
    format: kHalcyonDecodeOutputFormat,
  );

  final expectedLength = ceyxOutputFormatByteCount(
    kHalcyonDecodeOutputFormat,
    image.width,
    image.height,
  );
  if (image.rgbaData.length != expectedLength) {
    throw StateError(
      'ceyx returned rgbaData.length=${image.rgbaData.length} '
      'but ${image.width}x${image.height} '
      '${kHalcyonDecodeOutputFormat.name} needs $expectedLength',
    );
  }

  return DecodedRgba(
    rgba: image.rgbaData,
    width: image.width,
    height: image.height,
    format: kHalcyonDecodeOutputFormat,
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
///   route (spec §1.4), which is what lets `photo_source.dart:634`'s
///   `usePointer` gate flip to true with zero edits to that line.
Future<DecodedRgba> decodeDngFullOriented(
  String path, {
  required int exifOrientation,
}) async {
  ensureHalcyonDecodePoolConfigured();
  final image = await CeyxDecodePool.shared.decode(
    path,
    exifOrientation: exifOrientation,
    format: kHalcyonDecodeOutputFormat,
  );

  final expectedLength = ceyxOutputFormatByteCount(
    kHalcyonDecodeOutputFormat,
    image.width,
    image.height,
  );
  if (image.rgbaData.length != expectedLength) {
    throw StateError(
      'ceyx returned rgbaData.length=${image.rgbaData.length} '
      'but ${image.width}x${image.height} '
      '${kHalcyonDecodeOutputFormat.name} needs $expectedLength',
    );
  }

  return DecodedRgba(
    rgba: image.rgbaData,
    width: image.width,
    height: image.height,
    format: kHalcyonDecodeOutputFormat,
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

  _assertLoadedLibrarySupportsYuv420();

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

// --- mem8 T15a step 6: the R-J capability gate ----------------------------

/// Test seam for the gate's probe. Returns null when the loaded library CAN
/// service [kHalcyonDecodeOutputFormat], or the
/// [CeyxFormatUnsupportedException] the real lookup produced when it cannot.
///
/// A seam, not a mock of the lookup: the production probe below calls ceyx's
/// own unguarded binding, so a production lookup that swallowed the error
/// would still be caught. Tests that need the absent branch drive it through
/// `CeyxDecodePool.debugYuv420Available` (ceyx's own forced-absence seam) or
/// through this override.
@visibleForTesting
CeyxFormatUnsupportedException? Function()? debugYuv420GateProbe;

/// Set once the gate has passed, so the probe is paid once per process rather
/// than on every `ensureHalcyonDecodePoolConfigured` call. A FAILURE is never
/// latched: a stale pin must keep throwing, on every entry point, forever.
bool _yuv420GatePassed = false;

@visibleForTesting
void debugResetYuv420Gate() => _yuv420GatePassed = false;

/// Raises R-J's hard typed failure when the library this process actually
/// loaded predates the yuv420 arm.
///
/// WHY THIS IS NOT THE GUARDED-LOOKUP PATTERN USED EVERYWHERE ELSE HERE.
/// `dng_bindings.dart:419-470` wraps each `lookupFunction` in a swallowing
/// `catch` and nulls a whole group when one symbol is missing. That is the
/// right policy for a debug/tuning capability and the WRONG policy here: a
/// library without the yuv420 entries cannot produce the pixels this app is
/// about to interpret as planar yuv, so a silent rgba8 fallback hands back a
/// wrong image with no error — strictly worse than a crash. This campaign has
/// already shipped one silent-capability-absence defect of exactly that shape.
/// No arm of this gate may yield null, a bool, or a degraded-but-running
/// decoder.
///
/// IT FIRES AT POOL CONFIGURATION, NOT AT FIRST DECODE, so a stale pin fails
/// at startup rather than at the user's first navigation — a failure that
/// waits for a user action is one a headless acceptance run can miss.
///
/// ONE RULE, TWO LAYERS, deliberately. ceyx already refuses at `submit()`
/// (T14) with the SAME frozen exception type. This is an EARLIER check, not a
/// second rule, and two consequences are binding: Halcyon surfaces the
/// plugin's frozen type and never defines its own, and Halcyon NEVER catches
/// the plugin's submit-time throw anywhere — the plugin's refusal stays the
/// backstop, and catching it would reinstate exactly the silent degradation
/// R-J bans.
///
/// It is DISTINCT from `RawUnavailableException` (the "this build has no RAW
/// decoder" signal): reusing that routes a stale pin into the path for a
/// deliberately RAW-less build, and those need opposite responses.
///
/// ONE CODE PATH FOR ALL TARGETS — there is no `Platform.isX` here (R-N).
///
/// KNOWN COVERAGE GAP, flagged rather than silently dropped — and note that
/// yuv420 support is TWO independent capabilities, not one:
///
/// * the DECODE-FORMAT entries, probed inside ceyx by
///   `DngNativeBindings.yuv420DecodeAvailable` (`dng_bindings.dart:527`);
/// * the CONVERTER entry `ceyx_yuv420_to_rgba8`, probed by
///   `yuv420UpconvertAvailable` (`:531`).
///
/// A library carrying one without the other is a real state, so folding them
/// into a single bool would name the wrong fact in the R-J exception.
///
/// This gate probes the CONVERTER only, because that is the sole yuv420
/// capability ceyx currently exports to a host: `ceyxYuv420ToRgba8` is
/// reachable, while BOTH availability getters are unexported from
/// `plugin/lib/ceyx.dart` and `CeyxDecodePool._yuv420Available`
/// (`decode_pool.dart:847`) is private — and that private one forwards
/// `yuv420DecodeAvailable` ALONE (`:854`), so even exposing it would leave the
/// converter unprobed rather than close this gap. Two getters (or one that
/// ANDs them while reporting each separately) have been requested from the
/// plugin side; ownership of that edit sits with the lead, not with T13.
///
/// Until they exist the DECODE-FORMAT symbol is covered only by ceyx's own
/// submit-time refusal, which is the backstop rather than the startup check.
/// Do not close this gap by catching that refusal.
void _assertLoadedLibrarySupportsYuv420() {
  if (_yuv420GatePassed) return;

  final probe = debugYuv420GateProbe ?? _probeYuv420Converter;
  final failure = probe();
  if (failure != null) throw failure;
  _yuv420GatePassed = true;
}

/// The production probe: a 2x2 upconvert through ceyx's real, unguarded
/// binding. Two pixels cost nothing and exercise the genuine lookup.
///
/// Scratch memory comes from `CeyxNativeBufferPool` rather than from
/// `package:ffi`'s `calloc` — the pool is already a dependency, already
/// owns every native buffer in this pipeline, and adding an `ffi` dependency
/// for six bytes would be the wrong trade.
CeyxFormatUnsupportedException? _probeYuv420Converter() {
  // 2x2 yuv420 is 4 luma + 2 chroma = 6 bytes; the RGBA8 destination is 16.
  final srcBytes = ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, 2, 2);
  final dstBytes = ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, 2, 2);
  final pool = CeyxNativeBufferPool.shared;
  final src = pool.acquireOrNull(srcBytes);
  final dst = src == null ? null : pool.acquireOrNull(dstBytes);
  if (src == null || dst == null) {
    // Servable-without-waiting only: the gate must never block startup on a
    // busy pool. A pool that cannot serve six bytes right now says nothing
    // about the loaded library, so this is "not probed", not "not present" —
    // and it is not latched, so the next entry point probes again.
    if (src != null) pool.release(src);
    return null;
  }
  try {
    ceyxYuv420ToRgba8(
      srcAddress: src.address,
      srcCapacity: srcBytes,
      dstAddress: dst.address,
      dstCapacity: dstBytes,
      width: 2,
      height: 2,
    );
    return null;
  } on CeyxFormatUnsupportedException catch (e) {
    // NOT a swallow: the exception is RETURNED to the gate, which rethrows it.
    // The one case it is deliberately downgraded to "not a stale pin" is a
    // process where NO library could be opened at all — a plain Dart test
    // process — which ceyx reports with the `kCeyxNoLibraryLoaded` sentinel
    // and which is a different condition from the stale pin R-J diagnoses.
    // Loud either way: the sentinel case prints.
    if (e.libraryPath == kCeyxNoLibraryLoaded) {
      debugPrint(
        '[ceyx-pool] yuv420 gate: no native library is loaded in this '
        'process, so the capability could not be probed. This is expected in '
        'a pure-Dart test process and NEVER expected in the app.',
      );
      return null;
    }
    return e;
  } finally {
    pool.release(src);
    pool.release(dst);
  }
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
