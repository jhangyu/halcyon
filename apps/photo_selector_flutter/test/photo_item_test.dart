import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_selector_flutter/models/photo_item.dart';
import 'package:photo_selector_flutter/models/supported_photo_formats.dart';

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
  });
}
