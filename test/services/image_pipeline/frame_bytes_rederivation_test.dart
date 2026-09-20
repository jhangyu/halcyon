// T15a-pre (Task #14, 2026-09-20): the guard for P34.2's mandatory
// re-derivation of `kNominalFullFrameBytes`.
//
// P34.2 rules the re-derivation MANDATORY ("retain it with stated reasoning"
// was withdrawn): under a yuv420 decode output the pooled destination is
// 1.5 B/px, so a constant of 96,962,304 whose own dartdoc asserts a MEASURED
// 4 B/px byte count is a wrong number, not a safe margin.
//
// WHY THIS IS A GUARD AND NOT A STANDING RED (lead ruling, 2026-09-20).
// Written literally, "the failing test for the re-derivation" is red until
// T15b takes its capture, and a standing expected-red in the shared gate is
// the condition this campaign's ledger blames for losing a real regression —
// one known red is where the next one hides. So the obligation is pinned in
// its INVERTED form: the extent and the constant are ONE FACT, and this fails
// if they are ever updated apart, in either direction.
//
// *** T15b'S OBLIGATION, WHICH THIS TEST DOES NOT DISCHARGE ***
// Red-first is preserved for T15b, not pre-spent here. When T15b supplies the
// capture it MUST, in this order:
//   1. set `kMeasuredFullFrameExtent` from the fresh decode.ffi capture and
//      RUN THIS TEST FIRST, observing it GO RED (the extent is supplied while
//      the constant is still the rgba8 number — the "updated apart" arm below);
//   2. only then re-derive `kNominalFullFrameBytes` from that extent via
//      `ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h)` and watch it
//      go green;
//   3. rewrite the dartdoc in the same edit.
// A T15b that flips both in one edit never sees this red and therefore has no
// evidence the guard was ever wired to anything.
import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/frame_bytes.dart';

void main() {
  group('kNominalFullFrameBytes re-derivation (P34.2)', () {
    // TC-1301
    test(
      'the measured extent and the constant are one fact: neither may be '
      'updated without the other',
      () {
        // Read through a local so this is a runtime comparison rather than a
        // constant-folded branch the analyser can call dead code.
        final extent = kMeasuredFullFrameExtent;
        // The value the dartdoc cited BEFORE the flip, from capture_173023
        // (docs/logs/2026-09-06/gc-pressure-allocation-lens.md:9): 24 MP at
        // 4 B/px, the rgba8 decode output.
        const measuredRgba8Bytes = 96962304;

        // T15b (2026-09-20) made the extent NON-NULLABLE. The pre-capture arm
        // this test used to carry — "extent still null, so the constant must
        // still be the rgba8 number" — described a state that no longer exists
        // and is now unreachable by TYPE, which is a stronger guarantee than
        // the runtime check it replaces. The obligation itself is unchanged and
        // still bidirectional: the two assertions below fail if the extent is
        // moved without the constant (first) or the constant is left at the
        // rgba8 figure while an extent claims yuv420 (second).

        // A capture exists, so the constant must equal what the
        // FROZEN CONTRACT's formula says that extent costs in yuv420 — one
        // formula across both repos, never an open-coded second copy. The
        // ceil(w/2) term is load-bearing: an odd-dimension frame sized with
        // (w/2)*(h/2) under-allocates, and under yuv420 an under-allocation is
        // a heap overrun, not a miscount.
        expect(
          kNominalFullFrameBytes,
          ceyxOutputFormatByteCount(
            CeyxOutputFormat.yuv420,
            extent.width,
            extent.height,
          ),
          reason: 'an extent was supplied but the constant was not re-derived '
              'from it (or was derived with different arithmetic). These are '
              'one fact and must be updated in the same edit.',
        );
        expect(
          kNominalFullFrameBytes,
          isNot(measuredRgba8Bytes),
          reason: 'the constant is still the rgba8 measurement while an extent '
              'claims a yuv420 decode output: the flip was documented but not '
              'applied.',
        );
      },
    );

    // TC-1302 -- the contract formula this guard leans on, exercised at the
    // ODD dimensions the whole ceil() rule exists for. Without this, TC-1301's
    // green could rest on a formula that is itself wrong at the only extents
    // where it is interesting, and Halcyon would never notice because its own
    // frames happen to be even.
    test('the contract formula rounds chroma planes UP, not down', () {
      // 3x3: chroma planes are ceil(3/2)=2 per side, so 9 + 2*(2*2) = 17.
      // The under-allocating (w/2)*(h/2) form would say 9 + 2*1 = 11.
      expect(ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, 3, 3), 17);
      expect(ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, 4, 4), 24);
      expect(ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, 3, 3), 36);
    });
  });
}
