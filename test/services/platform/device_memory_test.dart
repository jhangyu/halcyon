import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/device_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(DeviceMemory.channel, null);
  });

  test('TC-310: no platform handler yields null, not a throw', () async {
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });

  test('TC-311: a positive reading is returned as-is', () async {
    messenger.setMockMethodCallHandler(DeviceMemory.channel, (call) async {
      expect(call.method, 'totalPhysicalBytes');
      return 17179869184; // 16 GiB
    });
    expect(await DeviceMemory.totalPhysicalBytes(), 17179869184);
  });

  test('TC-312: a null reply yields null', () async {
    messenger.setMockMethodCallHandler(
      DeviceMemory.channel,
      (call) async => null,
    );
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });

  test('TC-313: a non-positive reading is treated as absent', () async {
    messenger.setMockMethodCallHandler(
      DeviceMemory.channel,
      (call) async => 0,
    );
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });

  test('TC-314: a PlatformException yields null, not a throw', () async {
    messenger.setMockMethodCallHandler(DeviceMemory.channel, (call) async {
      throw PlatformException(code: 'BOOM');
    });
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });
}
