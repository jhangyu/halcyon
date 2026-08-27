import 'dart:io';

import 'package:ceyx/ceyx.dart' show kSupportedDecodeExtensions;
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/supported_photo_formats.dart';

void main() {
  group('SupportedPhotoFormats.decodableExtensions', () {
    test('derives exactly from kSupportedDecodeExtensions, dotted form', () {
      final expected =
          kSupportedDecodeExtensions.map((e) => '.${e.toLowerCase()}').toSet();
      // Fails if someone re-hardcodes the list instead of deriving it.
      expect(SupportedPhotoFormats.decodableExtensions, expected);
    });
  });

  group('D2 browse-only extensions (.cr2, .iiq, .mrw)', () {
    test('are NOT in decodableExtensions', () {
      for (final ext in ['.cr2', '.iiq', '.mrw']) {
        expect(
          SupportedPhotoFormats.decodableExtensions.contains(ext),
          isFalse,
          reason: '$ext must not be reported as engine-decodable (D2)',
        );
      }
    });

    test('ARE in rawExtensions and supportedExtensions', () {
      for (final ext in ['.cr2', '.iiq', '.mrw']) {
        expect(
          SupportedPhotoFormats.rawExtensions.contains(ext),
          isTrue,
          reason: '$ext must stay browsable (D2)',
        );
        expect(
          SupportedPhotoFormats.supportedExtensions.contains(ext),
          isTrue,
          reason: '$ext must stay browsable (D2)',
        );
      }
    });
  });

  group('isDecodablePath', () {
    test('true for an engine-decodable extension', () {
      expect(SupportedPhotoFormats.isDecodablePath('/tmp/a.dng'), isTrue);
    });

    test('false for a D2 browse-only extension', () {
      expect(SupportedPhotoFormats.isDecodablePath('/tmp/a.cr2'), isFalse);
    });

    test('false for an unsupported extension', () {
      expect(SupportedPhotoFormats.isDecodablePath('/tmp/a.heic'), isFalse);
    });
  });

  group('AC1 — folder scan surfaces a file of every derived-list extension', () {
    test('over a fake directory listing, every decodable+browse-only ext is picked up', () async {
      final tmpDir = await Directory.systemTemp.createTemp('halcyon_fmt_test_');
      addTearDown(() => tmpDir.delete(recursive: true));

      final allExts = SupportedPhotoFormats.rawExtensions
          .followedBy(const ['.jpg', '.jpeg', '.png']);
      var i = 0;
      for (final ext in allExts) {
        final f = File('${tmpDir.path}/file_${i++}$ext');
        await f.writeAsBytes(<int>[0]);
      }

      final entities = await tmpDir.list().toList();
      final foundExts = entities
          .whereType<File>()
          .map((f) => SupportedPhotoFormats.isSupportedPath(f.path))
          .toList();

      // Every file written used a supported extension, so every one must be
      // recognised as supported by the scan-facing predicate.
      expect(foundExts.every((v) => v), isTrue);
      expect(entities.length, allExts.toSet().length);
    });
  });

  group('rawExtensions / supportedExtensions composition', () {
    test('rawExtensions == decodableExtensions union browseOnlyRawExtensions', () {
      expect(
        SupportedPhotoFormats.rawExtensions,
        SupportedPhotoFormats.decodableExtensions
            .union(SupportedPhotoFormats.browseOnlyRawExtensions),
      );
    });

    test('supportedExtensions includes engine bitstreams, bitmap-decode and '
        'all raw extensions', () {
      expect(
        SupportedPhotoFormats.supportedExtensions,
        SupportedPhotoFormats.engineBitstreamExtensions
            .union(SupportedPhotoFormats.bitmapDecodeExtensions)
            .union(SupportedPhotoFormats.rawExtensions),
      );
    });
  });

  group('phase-1 bitmap formats', () {
    test('TC-302: .webp/.tif/.tiff are supported, .xyz is not', () {
      for (final path in ['a.webp', 'b.tif', 'c.tiff', 'D.WEBP', 'E.TIF']) {
        expect(
          SupportedPhotoFormats.isSupportedPath(path),
          isTrue,
          reason: '$path must survive the folder scan whitelist',
        );
      }
      expect(SupportedPhotoFormats.isSupportedPath('d.xyz'), isFalse);
      expect(SupportedPhotoFormats.isSupportedPath('e.heic'), isTrue,
          reason: 'phase 2 claims HEIC: the native libheif route exists');
      expect(SupportedPhotoFormats.isSupportedPath('f.HEIF'), isTrue,
          reason: 'extension matching is case-insensitive');
    });

    test('TC-302: .webp is an engine bitstream, .tif/.tiff are bitmap-decode',
        () {
      expect(SupportedPhotoFormats.isEncodedBitstreamPath('a.webp'), isTrue);
      expect(SupportedPhotoFormats.isBitmapDecodePath('a.webp'), isFalse);
      expect(SupportedPhotoFormats.isEncodedBitstreamPath('b.tif'), isFalse);
      expect(SupportedPhotoFormats.isBitmapDecodePath('b.tif'), isTrue);
      expect(SupportedPhotoFormats.isBitmapDecodePath('c.tiff'), isTrue);
      expect(SupportedPhotoFormats.bitmapDecodeExtensions,
          {'.tif', '.tiff', '.heic', '.heif'});
    });

    test('TC-302: hasFullDecodeRoute covers RAW and TIFF but not D2/bitstream',
        () {
      expect(SupportedPhotoFormats.hasFullDecodeRoute('b.tif'), isTrue);
      expect(SupportedPhotoFormats.hasFullDecodeRoute('c.tiff'), isTrue);
      expect(SupportedPhotoFormats.hasFullDecodeRoute('a.dng'), isTrue);
      for (final path in ['x.cr2', 'y.iiq', 'z.mrw']) {
        expect(
          SupportedPhotoFormats.hasFullDecodeRoute(path),
          isFalse,
          reason: 'D2 browse-only containers have no decode route',
        );
      }
      expect(SupportedPhotoFormats.hasFullDecodeRoute('a.webp'), isFalse);
      expect(SupportedPhotoFormats.hasFullDecodeRoute('a.jpg'), isFalse);
    });

    test('TC-304: bestFileToLoad prefers .jpg over .webp, .webp over .dng', () {
      File f(String name) => File(name);
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.webp'), f('a.jpg')])!.path,
        'a.jpg',
      );
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.png'), f('a.webp')])!.path,
        'a.png',
      );
      // The DNG is listed FIRST: a fallback that returns `supported.first`
      // would return the DNG, so this only passes if .webp is in
      // preferredLoadExtensions.
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.dng'), f('a.webp')])!.path,
        'a.webp',
      );
      // TIFF is deliberately NOT preferred over a JPEG sibling.
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.tif'), f('a.jpg')])!.path,
        'a.jpg',
      );
    });
  });

  group('phase-2 HEIC formats', () {
    test('TC-302: .heic/.heif are bitmap-decode, not engine bitstreams', () {
      for (final path in ['a.heic', 'b.heif', 'C.HEIC', 'D.HEIF']) {
        expect(SupportedPhotoFormats.isSupportedPath(path), isTrue);
        expect(SupportedPhotoFormats.isBitmapDecodePath(path), isTrue);
        expect(
          SupportedPhotoFormats.isEncodedBitstreamPath(path),
          isFalse,
          reason: 'the Flutter engine cannot decode HEIC on every platform, '
              'which is why it needs the native route at all',
        );
        expect(SupportedPhotoFormats.hasFullDecodeRoute(path), isTrue);
      }
      expect(SupportedPhotoFormats.bitmapDecodeExtensions,
          {'.tif', '.tiff', '.heic', '.heif'});
    });

    test('TC-302: a HEIC sibling does not outrank a JPEG sibling', () {
      File f(String name) => File(name);
      // HEIC is deliberately absent from preferredLoadExtensions, exactly like
      // TIFF: a rendered JPEG next to a HEIC is the cheaper, engine-decodable
      // file and must keep winning.
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.heic'), f('a.jpg')])!.path,
        'a.jpg',
      );
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.heic')])!.path,
        'a.heic',
        reason: 'the supported-file fallback still picks it up when the whole '
            'group is HEIC',
      );
    });
  });
}
