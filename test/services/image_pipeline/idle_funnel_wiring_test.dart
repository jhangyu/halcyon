import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';

void main() {
  tearDown(() {
    CeyxNativeBufferPool.debugArenaIdleShrinkOverride = null;
    CeyxNativeBufferPool.debugPressureReliefOverride = null;
    CeyxNativeBufferPool.debugResetNativeBindingsCache();
  });

  test('TC-1433 the app decode pool reaches the native idle funnel even when '
      'no Dart buffer is freed (same path on every platform)', () {
    final floors = <int>[];
    CeyxNativeBufferPool.debugPressureReliefOverride = () => 0;
    CeyxNativeBufferPool.debugArenaIdleShrinkOverride = (int floor) {
      floors.add(floor);
      return 0;
    };
    ensureHalcyonDecodePoolConfigured();

    CeyxNativeBufferPool.shared.shrinkToFloor();

    expect(CeyxDecodePool.nativeBufferPool, same(CeyxNativeBufferPool.shared));
    expect(floors, <int>[CeyxNativeBufferPool.shared.idleFloor]);
  });
}
