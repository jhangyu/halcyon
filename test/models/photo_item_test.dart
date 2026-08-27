import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/models/supported_photo_formats.dart';

void main() {
  group('PhotoItem.bestFileToLoad', () {
    test('prefers JPG over RAW files in the same group', () {
      final item = PhotoItem(
        id: 'IMG_0001',
        files: [File('/tmp/IMG_0001.arw'), File('/tmp/IMG_0001.jpg')],
      );

      expect(item.bestFileToLoad?.path, endsWith('IMG_0001.jpg'));
    });

    test('falls back to the first RAW file when no preview format exists', () {
      final item = PhotoItem(
        id: 'IMG_0001',
        files: [File('/tmp/IMG_0001.arw'), File('/tmp/IMG_0001.dng')],
      );

      expect(item.bestFileToLoad?.path, endsWith('IMG_0001.arw'));
    });
  });

  group('SupportedPhotoFormats', () {
    test('central registry includes RW2 and excludes unsupported files', () {
      expect(
        SupportedPhotoFormats.isSupportedPath('/tmp/P1000001.rw2'),
        isTrue,
      );
      expect(SupportedPhotoFormats.isSupportedPath('/tmp/notes.txt'), isFalse);
      expect(SupportedPhotoFormats.isRawPath('/tmp/P1000001.rw2'), isTrue);
    });

    test('HEIC is scanned in phase 2, and never outranks a cheap engine sibling',
        () {
      // Phase-2 boundary: HEIC joined bitmapDecodeExtensions (native libheif
      // route), so it is now a supported, scanned container — the inverse of
      // the phase-1 assertion this replaces.
      expect(SupportedPhotoFormats.isSupportedPath('/x/a.heic'), isTrue);
      // The invariant that is actually decided: a HEIC must not outrank a
      // rendered, engine-decodable JPEG sibling — HEIC is deliberately absent
      // from preferredLoadExtensions, exactly like TIFF. (A HEIC vs a RAW
      // sibling is left to list order, the same as TIFF vs RAW; a deliberate
      // ranking there would be a new product decision.)
      final files = [File('/x/a.heic'), File('/x/a.jpg')];
      expect(SupportedPhotoFormats.bestFileToLoad(files)!.path, '/x/a.jpg');
    });
  });
}
