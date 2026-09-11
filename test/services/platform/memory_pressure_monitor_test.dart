import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/memory_pressure_monitor.dart';

/// TC-1160..TC-1164 (WP4.4 / S3.4): the wire-format -> enum mapping and the
/// change-only emission contract of [MemoryPressureMonitor].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodCall pressure(Object? argument) =>
      MethodCall(MemoryPressureMonitor.methodName, argument);

  group('MemoryPressureMonitor', () {
    test('TC-1160 starts calm before the platform says anything', () {
      final monitor = MemoryPressureMonitor();
      expect(monitor.currentPressureLevel, MemoryPressureLevel.normal);
    });

    test('TC-1161 maps each wire name to its level and emits on change',
        () async {
      final monitor = MemoryPressureMonitor();
      final seen = <MemoryPressureLevel>[];
      final subscription = monitor.pressureLevelChanges.listen(seen.add);

      await monitor.handleMethodCall(pressure('warning'));
      expect(monitor.currentPressureLevel, MemoryPressureLevel.warning);
      await monitor.handleMethodCall(pressure('critical'));
      expect(monitor.currentPressureLevel, MemoryPressureLevel.critical);
      await monitor.handleMethodCall(pressure('normal'));
      expect(monitor.currentPressureLevel, MemoryPressureLevel.normal);

      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        MemoryPressureLevel.warning,
        MemoryPressureLevel.critical,
        MemoryPressureLevel.normal,
      ]);
      await subscription.cancel();
      await monitor.dispose();
    });

    test('TC-1162 a repeated level emits nothing (platforms re-announce)',
        () async {
      final monitor = MemoryPressureMonitor();
      final seen = <MemoryPressureLevel>[];
      final subscription = monitor.pressureLevelChanges.listen(seen.add);

      await monitor.handleMethodCall(pressure('warning'));
      await monitor.handleMethodCall(pressure('warning'));
      await monitor.handleMethodCall(pressure('warning'));

      await Future<void>.delayed(Duration.zero);
      expect(seen, [MemoryPressureLevel.warning]);
      await subscription.cancel();
      await monitor.dispose();
    });

    test('TC-1163 unknown argument and unknown method are ignored, not thrown',
        () async {
      final monitor = MemoryPressureMonitor();
      final seen = <MemoryPressureLevel>[];
      final subscription = monitor.pressureLevelChanges.listen(seen.add);

      await monitor.handleMethodCall(pressure('catastrophic'));
      await monitor.handleMethodCall(pressure(42));
      await monitor.handleMethodCall(pressure(null));
      await monitor.handleMethodCall(const MethodCall('somethingElse', 'warning'));

      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
      expect(monitor.currentPressureLevel, MemoryPressureLevel.normal);
      await subscription.cancel();
      await monitor.dispose();
    });

    test('TC-1164 startListening receives a push over the real channel',
        () async {
      final monitor = MemoryPressureMonitor();
      monitor.startListening();
      final seen = <MemoryPressureLevel>[];
      final subscription = monitor.pressureLevelChanges.listen(seen.add);

      // Exactly the shape the native side sends: bare String argument on
      // halcyon/memory_pressure, method memoryPressureLevelChanged.
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .handlePlatformMessage(
            MemoryPressureMonitor.channelName,
            codec.encodeMethodCall(pressure('warning')),
            (_) {},
          );

      await Future<void>.delayed(Duration.zero);
      expect(seen, [MemoryPressureLevel.warning]);
      expect(monitor.currentPressureLevel, MemoryPressureLevel.warning);
      await subscription.cancel();
      await monitor.dispose();
    });
  });
}
