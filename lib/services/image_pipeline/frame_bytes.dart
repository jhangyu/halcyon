import 'dart:math' as math;

import 'retention_policy.dart';

/// One full-resolution **decode-output** frame, MEASURED: every `decode.ffi`
/// event in capture_173023 was exactly 96,962,304 bytes (24 MP, 4 B/px).
/// Source: docs/logs/2026-09-06/gc-pressure-allocation-lens.md:9.
///
/// Used as the PRE-DECODE estimate for an expensive item: the real size is
/// unknown until the decode returns, and every admission is reconciled to the
/// real value afterwards via [InflightBytesBudget.adjust].
///
/// TWO DIFFERENT BUFFERS, and conflating them is how this constant goes wrong
/// (P34.2). The 4 B/px above describes the **decode output**, which the mem8
/// v3 campaign's yuv420 flip (T15a) takes to 1.5 B/px. It does NOT describe
/// the **transient display buffer**, which stays 4 B/px permanently: Flutter's
/// `decodeImageFromPixels` accepts RGBA only, so the upconvert's destination
/// genuinely is 4 B/px no matter what the decoder emits. The consumers of this
/// constant split along exactly that line — the sweep and each consumer's
/// disposition are in `docs/logs/2026-09-20/t15a-pre-consumer-sweep.txt`, and
/// the one consumer that measures DISPLAY bytes
/// (`image_preload_controller.dart:599`, whose charges are `w*h*4` ui.Image
/// uploads) must not silently follow the decode side down.
///
/// PENDING RE-DERIVATION (P34.2, mandatory — the "retain it with stated
/// reasoning" alternative was withdrawn by ruling). T15a flips the decode
/// output to yuv420; the replacement value is DERIVED FROM A FRESH
/// `decode.ffi` CAPTURE in T15b, not computed on paper, and it must agree with
/// `ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h)` — one formula
/// across both repos, never a second open-coded copy, because the `ceil(w/2)`
/// term is load-bearing and an odd-dimension frame sized with `(w/2)*(h/2)`
/// under-allocates and is written past. The capture goes into
/// [kMeasuredFullFrameExtent].
const int kNominalFullFrameBytes = 96962304;

/// The pixel extent behind [kNominalFullFrameBytes], as read off a real
/// `decode.ffi` capture — **null until T15b takes that capture**.
///
/// Deliberately not a number today (T15a-pre, Task #14): the byte count above
/// is a measurement, so its extent has to be one too. Writing a plausible
/// 24 MP width/height here would manufacture exactly the kind of citation this
/// project has been bitten by — a dartdoc that reads as measured while naming
/// a buffer nobody observed.
///
/// T15b supplies it and re-derives [kNominalFullFrameBytes] from it **in the
/// same edit**; the two are one fact and must never be updated apart.
const ({int width, int height})? kMeasuredFullFrameExtent = null;

/// One full-resolution **transient DISPLAY buffer**, 4 B/px — the family-B
/// constant the mem8 T15a split creates (lead pre-ruling 2026-09-20).
///
/// SEPARATE FROM [kNominalFullFrameBytes] ON PURPOSE, and the separation is a
/// correctness requirement forced by Flutter's API rather than a preference.
/// After T15a the decode OUTPUT is planar yuv420 at 1.5 B/px, so
/// [kNominalFullFrameBytes] re-derives downward at T15b. The DISPLAY buffer
/// does not move with it: `ui.decodeImageFromPixels` accepts RGBA only, so
/// `materialiseRgba`'s upconvert destination — and every `ui.Image` upload
/// charged against the publish pacer — is genuinely 4 B/px forever.
///
/// THE DEFECT THIS PREVENTS, stated so nobody "simplifies" the two back into
/// one: re-deriving a single shared constant to the yuv420 value would
/// silently shrink the publish pacer's quota by ~2.7x as a side effect, while
/// the costs charged against that quota (`image.width * image.height * 4` at
/// `tier_two_scheduler.dart:270`, `payload.byteCost` at `:323`) would not
/// shrink at all. A quota and its charges must be in the same units.
///
/// Its value is today's measured 24 MP RGBA figure carried across unchanged —
/// the display buffer is exactly what that capture measured, so this constant
/// inherits the measurement rather than needing a new one. **T15b supplies
/// family A's number ONLY and must not touch this one.**
const int kNominalFullFrameDisplayBytes = 96962304;

/// The fraction of total physical memory the decode in-flight budget may
/// occupy. A SAFETY CEILING only, never the primary driver (decision D1-a,
/// 2026-09-11): at the widest lane setting (8 -> 9 nominal frames =
/// 872,660,736 B) this binds only below ~3.5 GB of physical memory, so on
/// every machine Halcyon targets the LANE WIDTH decides the budget and the RAM
/// reading does not.
const int decodeInflightBudgetMemoryCeilingPercent = 25;

/// The byte budget for transient full-frame buffers held by DECODES in flight.
///
/// Derived from the configured decode lane width alone -- NOT from the
/// retention tier (S1.4). The old derivation read `RetentionPolicy`'s
/// `payloadByteBudget`, which is a RETENTION number (how much decoded pixel
/// data is kept) being used to gate DECODE CONCURRENCY; on the conservative
/// tier that capped decode parallelism at two frames no matter how wide the
/// lane was set. The retention *policy* is no longer read here at all; the
/// `retention_policy.dart` import survives solely for [kMaxDecodeLaneWidth],
/// so the measured-safe width ceiling keeps exactly one owner.
///
/// Evaluation order (decision D1-b): frame count = `decodeLaneWidth + 1`
/// clamped to `[2, kMaxDecodeLaneWidth + 1]`; times [kNominalFullFrameBytes];
/// then `min` with the physical-memory ceiling; then `max` with two nominal
/// frames. That trailing floor is load-bearing -- it preserves the historical
/// two-frame floor on a small machine, so the ceiling can never drive the
/// budget below what shipped before. A single frame larger than the whole
/// budget is still admitted alone by
/// [InflightBytesBudget]'s oversize-single-item hatch, so no configuration can
/// wedge.
///
/// The `+ 1` is the pipelining frame: `decodeLaneWidth` decodes in flight plus
/// one being handed to the next stage.
///
/// [physicalMemoryBytes] is optional and defaults to null: a null, zero or
/// negative reading means "no ceiling", which is the behaviour on every
/// platform without a total-physical-memory reading and in every test.
int decodeInflightByteBudget({
  required int decodeLaneWidth,
  int? physicalMemoryBytes,
}) {
  final frameCount = (decodeLaneWidth + 1).clamp(2, kMaxDecodeLaneWidth + 1);
  var budget = frameCount * kNominalFullFrameBytes;
  if (physicalMemoryBytes != null && physicalMemoryBytes > 0) {
    budget = math.min(
      budget,
      physicalMemoryBytes * decodeInflightBudgetMemoryCeilingPercent ~/ 100,
    );
  }
  return math.max(budget, 2 * kNominalFullFrameBytes);
}

/// The ACCOUNTING ceiling for the encode/publish tail -- the frames that have
/// left the decode lane but are still alive through encode, publication pacing
/// and the idle-publish wait (S1.3, decision D1-d).
///
/// Sized in NOMINAL frames because a ceiling is sized for the worst case, while
/// every CHARGE against it is the REAL post-decode frame size (lead directive
/// 2026-09-11). The tail ledger never refuses
/// ([InflightBytesBudget.chargeWithoutAdmission]): the bytes already exist by
/// the time it is charged, the stage's concurrency is already bounded by
/// `EncodeStage.width`, so this is an attribution instrument and an over-run
/// detector, not a gate.
/// FAMILY B, ruled 2026-09-20 (mem8 T15a). This ceiling is sized in DISPLAY
/// units, not decode-output units, and the reason is that the frames it
/// accounts for have already been upconverted: after T15a every consumer
/// reaches full-resolution pixels through `decodedRgbaToOrientedFullRes`,
/// which returns RGBA. So the real post-decode sizes charged here are 4 B/px,
/// and a ceiling must be in the same units as its charges.
///
/// The earlier reading — "the tail is charged the REAL post-decode size, so it
/// follows the decode format" — was right about the mechanism and wrong about
/// the conclusion once the seam landed: those real sizes are now RGBA sizes
/// too. Leaving this on [kNominalFullFrameBytes] would have shrunk the ceiling
/// ~2.7x the moment T15b re-derives family A, silently and with nothing red.
/// Pinned by TC-1342.
int encodePublishTailByteBudget({required int encodeStageWidth}) =>
    encodeStageWidth.clamp(1, kMaxDecodeLaneWidth) *
    kNominalFullFrameDisplayBytes;
