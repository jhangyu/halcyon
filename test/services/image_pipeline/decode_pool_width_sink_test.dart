import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';

/// R4 item 1 — three-layer parallelism sync, Halcyon (layer 1) half.
///
/// These prove the HOST end of AC-1a: the user's decode-lane width reaches the
/// ceyx decode pool AND is pushed onward as the native slot target, as one
/// indivisible assignment. The native end (the slot pool actually running at
/// N != 4) is proven by the native gates, not from Dart.
///
/// No test here reaches the real dylib: `CeyxDecodePool.shared` is only
/// configured, never pumped, so no worker isolate is spawned.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PerfLog.testSink = null;
    setHalcyonDecodePoolWidth(2);
    debugDecodeWidthRecommendationsOverride = null;
  });

  test(
    'TC-960: setHalcyonDecodePoolWidth sets the pool width AND the native slot '
    'target, and logs the request',
    () {
      final lines = <String>[];
      PerfLog.testSink = lines.add;

      setHalcyonDecodePoolWidth(6);

      expect(CeyxDecodePool.shared.width, 6);
      expect(CeyxDecodePool.shared.nativeSlotTarget, 6);
      expect(lines, contains('lane.native_slots|requested=6'));
    },
  );

  test('TC-961: the Dart width and the native slot target cannot diverge', () {
    for (final w in <int>[1, 3, 5, 8]) {
      setHalcyonDecodePoolWidth(w);
      expect(
        CeyxDecodePool.shared.nativeSlotTarget,
        CeyxDecodePool.shared.width,
        reason: 'width and native slot target are one setting, not two',
      );
      expect(CeyxDecodePool.shared.width, w);
    }
  });

  test(
    'TC-962: a width above the machine recommendation propagates UNCLAMPED '
    '(ruling r-6)',
    () {
      // The machine reports a recommendation of 2 for the default class, and
      // the user asks for the slider maximum of 8. Ruling r-6: the user wins,
      // end to end. If any layer ever starts consulting the recommendation as
      // a clamp, this test is what fails.
      debugDecodeWidthRecommendationsOverride = () => <int>[3, 2, 1];

      final lines = <String>[];
      PerfLog.testSink = lines.add;

      setHalcyonDecodePoolWidth(8);

      expect(CeyxDecodePool.shared.width, 8);
      expect(CeyxDecodePool.shared.nativeSlotTarget, 8);
      expect(lines, contains('lane.native_slots|requested=8'));
      expect(
        halcyonDecodeWidthRecommendations(),
        <int>[3, 2, 1],
        reason: 'the recommendation is still readable — it is just not applied',
      );
    },
  );
}
