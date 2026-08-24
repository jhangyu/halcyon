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

    test('HEIC is not scanned, and never preferred over a decodable sibling', () {
      expect(SupportedPhotoFormats.isSupportedPath('/x/a.heic'), isFalse);
      final files = [File('/x/a.heic'), File('/x/a.arw')];
      // A HEIC that slipped into an item (pre-removal folder state) must not
      // win preference — the old list preferred the one file that cannot
      // decode anywhere (supported_photo_formats.dart:47-56 bug).
      expect(SupportedPhotoFormats.bestFileToLoad(files)!.path, '/x/a.arw');
    });
  });
}
