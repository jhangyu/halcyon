import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('halcyon/thumbnail');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('NativeThumbnailService.requestImage', () {
    test('NO_EMBEDDED_PREVIEW yields NativeImageNeedsRawDecode with parsed orientation', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NO_EMBEDDED_PREVIEW', details: 6);
      });

      final result = await NativeThumbnailService.requestImage('/x.dng');

      expect(result, isA<NativeImageNeedsRawDecode>());
      expect((result as NativeImageNeedsRawDecode).exifOrientation, 6);
    });

    test('other PlatformException codes yield NativeImageFailure', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'LOAD_FAILED', message: 'boom');
      });

      final result = await NativeThumbnailService.requestImage('/x.dng');

      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'LOAD_FAILED');
    });

    test('legacy getThumbnail returns null for non-NO_EMBEDDED_PREVIEW failures', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'LOAD_FAILED', message: 'boom');
      });

      final bytes = await NativeThumbnailService.getThumbnail('/x.dng');

      expect(bytes, isNull);
    });

    test('bad or absent details degrade to default orientation 1', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NO_EMBEDDED_PREVIEW');
      });

      final result = await NativeThumbnailService.requestImage('/x.dng');

      expect(result, isA<NativeImageNeedsRawDecode>());
      expect((result as NativeImageNeedsRawDecode).exifOrientation, kDefaultExifOrientation);
    });

    test('out-of-range details also degrade to default orientation', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NO_EMBEDDED_PREVIEW', details: 42);
      });

      final result = await NativeThumbnailService.requestImage('/x.dng');

      expect(result, isA<NativeImageNeedsRawDecode>());
      expect((result as NativeImageNeedsRawDecode).exifOrientation, kDefaultExifOrientation);
    });

    test('requestImage sends allowRawDecodeSignal true by default', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await NativeThumbnailService.requestImage('/x.dng');

      final args = captured!.arguments as Map;
      expect(args[kAllowRawDecodeSignalArg], true);
    });

    test('getThumbnail forces allowRawDecodeSignal false', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await NativeThumbnailService.getThumbnail('/x.dng');

      final args = captured!.arguments as Map;
      expect(args[kAllowRawDecodeSignalArg], false);
    });

    // The native branch in macos/Runner/AppDelegate.swift keys off the literal
    // string "export" and relies on the 2048 cap arriving in targetSize. A
    // mismatch here would silently fall through to the preview/thumbnail path
    // and return wrongly-sized bytes with no error, so pin both values.
    test('export purpose crosses the channel as "export" with a 2048 cap', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return null;
      });

      await NativeThumbnailService.getThumbnail(
        '/x.jpg',
        purpose: ImageRequestPurpose.export,
      );

      final args = captured!.arguments as Map;
      expect(args['purpose'], 'export');
      expect(args['targetSize'], 2048);
    });
  });
}
