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

  // TC-047/TC-048 (deleted, M6 F-14): both pinned single-platform semantics
  // of the now-deleted `halcyon/exif` channel path (chunking observed via a
  // channel mock; degrade-to-null on a mocked PlatformException). Neither
  // assertion is meaningful once `_readChunk` never reaches a channel at
  // all — replaced below by TC-120, which proves the channel is never
  // touched and pins chunking + failure-tolerance against the real isolate
  // parser instead of a mock. Not present in baseline-registry.md's frozen
  // sha256 list, so no re-registration is required (C-4).
  //
  // TC-120 (renumbered from a colliding TC-049, P5.2 audit — TC-049 is
  // app_state_test.dart's renameByExif case) mocks the channel by name via
  // `ExifMetadataService.channel`: that field was deleted along with the
  // production channel call (F-14, C-3-adjacent — no lingering channel
  // handle in lib/), so the AC that `lib/` and `macos/` grep clean for
  // "halcyon/exif" holds; the mock target here is only ever the name string,
  // matching how the platform channel is identified regardless of side.
  test('TC-120 readBatch never touches a platform channel', () async {
    const probeChannel = MethodChannel('halcyon/exif');
    var channelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(probeChannel, (call) async {
      channelCalls++;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(probeChannel, null);
    });

    // Chunking still applies (kExifChunkSize per call to _readChunk), proven
    // against the real isolate-parser path: unreadable paths degrade to null
    // rather than throwing, and the channel is never invoked either way.
    final paths = [for (var i = 0; i < 1200; i++) '/nonexistent/$i.JPG'];
    final result = await ExifMetadataService.readBatch(paths);

    expect(result, hasLength(1200));
    expect(result, everyElement(isNull));
    expect(channelCalls, 0);
  });
}
