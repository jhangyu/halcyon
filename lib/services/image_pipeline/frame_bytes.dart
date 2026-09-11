import 'dart:math' as math;

import 'retention_policy.dart';

/// One full-resolution RGBA8 frame, MEASURED: every `decode.ffi` event in
/// capture_173023 was exactly 96,962,304 bytes (24 MP, 4 B/px).
/// Source: docs/logs/2026-09-06/gc-pressure-allocation-lens.md:9.
///
/// Used as the PRE-DECODE estimate for an expensive item: the real size is
/// unknown until the decode returns, and every admission is reconciled to the
/// real value afterwards via [InflightBytesBudget.adjust].
const int kNominalFullFrameBytes = 96962304;

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
int encodePublishTailByteBudget({required int encodeStageWidth}) =>
    encodeStageWidth.clamp(1, kMaxDecodeLaneWidth) * kNominalFullFrameBytes;
