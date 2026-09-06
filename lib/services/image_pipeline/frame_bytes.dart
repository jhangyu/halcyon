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

/// The in-flight byte budget for a retention policy.
///
/// The old derivation was one quarter of `payloadByteBudget`, i.e. 64 MiB on
/// the floor tier, which is SMALLER THAN ONE FRAME -- so every admission took the
/// `_inFlight == 0` oversize-single-item hatch and the pipeline serialised to
/// one frame at a time regardless of `StageWidths.encode` (lifetime lens F1).
/// The floor is therefore two frames: one in flight plus one pipelining.
int inflightByteBudgetFor(RetentionPolicy policy) => math.max(
      2 * kNominalFullFrameBytes,
      policy.payloadByteBudget,
    );
