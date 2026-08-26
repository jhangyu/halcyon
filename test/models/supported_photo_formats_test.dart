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

    test('supportedExtensions includes jpg/jpeg/png plus all raw extensions', () {
      expect(
        SupportedPhotoFormats.supportedExtensions,
        {'.jpg', '.jpeg', '.png'}.union(SupportedPhotoFormats.rawExtensions),
      );
    });
  });
}
