import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/exif_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TC-045 decodes a full native map', () {
    final meta = ExifMetadataService.metadataFromMap({
      'captureDate': '2026:04:07 09:03:05',
      'camera': 'ILCE-7M4',
      'lens': 'FE 24-70mm F2.8 GM',
      'make': 'SONY',
      'artist': 'Jhang Yu',
      'shutter': '1/250',
      'aperture': 2.8,
      'focalLength': 35.0,
      'direction': 127.4,
      'iso': 400,
    });

    expect(meta!.captureDate, DateTime(2026, 4, 7, 9, 3, 5));
    expect(meta.camera, 'ILCE-7M4');
    expect(meta.lens, 'FE 24-70mm F2.8 GM');
    expect(meta.make, 'SONY');
    expect(meta.artist, 'Jhang Yu');
    expect(meta.shutter, '1/250');
    expect(meta.aperture, 2.8);
    expect(meta.focalLength, 35.0);
    expect(meta.gpsImgDirection, 127.4);
    expect(meta.iso, 400);
  });

  test('TC-046 a null map, a missing date and a junk date all degrade', () {
    expect(ExifMetadataService.metadataFromMap(null), isNull);

    final empty = ExifMetadataService.metadataFromMap({});
    expect(empty, isNotNull);
    expect(empty!.captureDate, isNull);
    expect(empty.camera, isNull);

    final junk = ExifMetadataService.metadataFromMap({'captureDate': 'nope'});
    expect(junk!.captureDate, isNull);
  });

  test('TC-047 readBatch chunks the paths and preserves order', () async {
    final seenChunks = <int>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExifMetadataService.channel, (call) async {
      final paths = (call.arguments as Map)['paths'] as List;
      seenChunks.add(paths.length);
      return [
        for (final path in paths) {'camera': path.toString().split('/').last},
      ];
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExifMetadataService.channel, null);
    });

    final paths = [for (var i = 0; i < 1200; i++) '/photos/$i.JPG'];
    final result = await ExifMetadataService.readBatch(paths);

    expect(seenChunks, [kExifChunkSize, kExifChunkSize, 200]);
    expect(result, hasLength(1200));
    expect(result.first!.camera, '0.JPG');
    expect(result.last!.camera, '1199.JPG');
  });

  test('TC-048 a channel failure yields nulls rather than throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExifMetadataService.channel, (call) async {
      throw PlatformException(code: 'BOOM');
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExifMetadataService.channel, null);
    });

    final result = await ExifMetadataService.readBatch(['/photos/a.JPG']);
    expect(result, [null]);
  });
}
