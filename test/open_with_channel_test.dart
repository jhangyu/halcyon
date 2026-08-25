import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/open_with_channel.dart';

// M6 P4.5 (F-16): Open With is now wired for Android/iOS too (manifest /
// Info.plist declarations + native push senders), but the channel contract
// Dart sees is unchanged -- native pushes an "openFile" call, Dart delivers
// the path to whatever OpenWithChannel.listen() was given. This test proves
// that delivery mechanically; it does NOT exercise Android/iOS native code
// (no device/simulator on this host) and does NOT claim the end-to-end
// mobile flow works -- folder-scan (F-02) is still parked on Android/iOS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('halcyon/open_with');
  const codec = StandardMethodCodec();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMessageHandler(channel.name, null);
  });

  test('a pushed openFile call is delivered to the listener', () async {
    final received = <String>[];
    OpenWithChannel.listen(received.add);

    final call = codec.encodeMethodCall(
      const MethodCall('openFile', '/tmp/example.dng'),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, call, (_) {});

    expect(received, ['/tmp/example.dng']);
  });

  test('an empty path is ignored', () async {
    final received = <String>[];
    OpenWithChannel.listen(received.add);

    final call = codec.encodeMethodCall(const MethodCall('openFile', ''));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, call, (_) {});

    expect(received, isEmpty);
  });

  test('an unrecognised method is ignored', () async {
    final received = <String>[];
    OpenWithChannel.listen(received.add);

    final call = codec.encodeMethodCall(
      const MethodCall('somethingElse', '/tmp/example.dng'),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, call, (_) {});

    expect(received, isEmpty);
  });
}
