import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/trash_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('halcyon/trash');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('PlatformException is an operation failure, not a missing bridge',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'TRASH_FAILED', message: 'denied');
    });
    try {
      await TrashService.trashFile(File('/tmp/x.jpg'));
      fail('expected TrashException');
    } on TrashException catch (e) {
      expect(e.bridgeUnavailable, isFalse);
    }
  });

  test('a missing handler is reported as bridge-unavailable', () async {
    // No mock handler registered => MissingPluginException.
    try {
      await TrashService.trashFile(File('/tmp/x.jpg'));
      fail('expected TrashException');
    } on TrashException catch (e) {
      expect(e.bridgeUnavailable, isTrue);
    }
  });
}
