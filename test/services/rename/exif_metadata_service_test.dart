import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/rename/exif_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
