import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dng_preview_extractor.dart';

/// Task #1 (dng-dart-preview, AC1/AC2): pure-Dart port of
/// macos/Runner/DngPreviewExtractor.swift.
///
/// Every non-trivial-input assertion below runs against REAL DNG samples
/// under local_data/photo_samples/DNG/ (per repo red line: real photos only
/// from that directory, never a user's own library). Byte counts were
/// cross-checked against the shipped Swift extractor compiled standalone
/// (scripts/tmp/run_dng_extractor_tests.sh harness pattern) and matched
/// exactly for all 14 samples in that directory before this test was
/// written -- see scripts/tmp/verify/dng_preview_extractor_dart_vs_swift.txt.
void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');

  test('sample directory exists with at least one DNG', () {
    expect(
      sampleDir.existsSync(),
      isTrue,
      reason: 'missing ${sampleDir.path}; cannot run real-sample tests',
    );
    final dngFiles = sampleDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.dng'))
        .toList();
    expect(dngFiles, isNotEmpty);
  });

  group('extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview', () {
    // These 13 samples are known (from the Swift reference cross-check) to
    // carry a qualifying embedded full-size JPEG preview.
    const withPreview = <String>[
      '2026-02-15-19-37-38.dng',
      '2026-02-15-20-53-24.dng',
      '2026-02-15-20-53-31.dng',
      '2026-02-15-20-57-15.dng',
      '2026-02-15-20-57-23-2.dng',
      '2026-02-15-20-57-23.dng',
      '2026-02-15-20-57-26.dng',
      '2026-02-15-20-57-28.dng',
      '2026-02-15-21-53-33.dng',
      '2026-02-15-21-53-41.dng',
      '2026-02-15-21-53-42.dng',
      '2026-02-15-21-53-43.dng',
      '2026-08-07-17-52-54.dng',
    ];

    for (final name in withPreview) {
      test('$name: extracts a decodable SOI/EOI-bounded JPEG', () async {
        final path = '${sampleDir.path}/$name';
        expect(File(path).existsSync(), isTrue, reason: 'missing $path');

        final bytes = await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(
          path,
        );
        expect(bytes, isNotNull, reason: '$name expected an embedded preview');
        expect(bytes!.length, greaterThan(4));
        expect(bytes[0], 0xFF, reason: 'SOI marker byte 0');
        expect(bytes[1], 0xD8, reason: 'SOI marker byte 1');
        expect(bytes[bytes.length - 2], 0xFF, reason: 'EOI marker byte 0');
        expect(bytes[bytes.length - 1], 0xD9, reason: 'EOI marker byte 1');

        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0));
        expect(frame.image.height, greaterThan(0));
        frame.image.dispose();
        codec.dispose();
      });
    }
  });

  test(
    'IMG_20251112_092839.dng (no qualifying embedded preview) returns null, not a crash',
    () async {
      final path = '${sampleDir.path}/IMG_20251112_092839.dng';
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');
      final bytes = await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(
        path,
      );
      expect(bytes, isNull);
    },
  );

  test('orientation tag: sample with EXIF orientation 6 is read and injected', () async {
    final path = '${sampleDir.path}/2026-08-07-17-52-54.dng';
    final data = await File(path).readAsBytes();
    final orientation = DngPreviewExtractor.readDngOrientation(data);
    expect(orientation, 6);

    final bytes = DngPreviewExtractor.extractFullSizeEmbeddedJpeg(data);
    expect(bytes, isNotNull);
    // Orientation != 1 means the extractor must have injected an APP1/Exif
    // segment right after SOI (0xFFE1 marker at offset 2).
    expect(bytes![2], 0xFF);
    expect(bytes[3], 0xE1);
  });

  group('malformed/truncated/non-DNG input degrades to null, never throws', () {
    test('empty bytes', () {
      expect(
        DngPreviewExtractor.extractFullSizeEmbeddedJpeg(Uint8List(0)),
        isNull,
      );
    });

    test('too short to contain a TIFF header', () {
      expect(
        DngPreviewExtractor.extractFullSizeEmbeddedJpeg(Uint8List.fromList([1, 2, 3])),
        isNull,
      );
    });

    test('wrong byte-order marker (not II/MM)', () {
      final data = Uint8List.fromList(List.filled(16, 0));
      data[0] = 0x00;
      data[1] = 0x00;
      expect(DngPreviewExtractor.extractFullSizeEmbeddedJpeg(data), isNull);
    });

    test('valid byte-order marker but garbage magic/IFD offset', () {
      final data = Uint8List.fromList(List.filled(16, 0xAB));
      data[0] = 0x49;
      data[1] = 0x49; // "II"
      expect(DngPreviewExtractor.extractFullSizeEmbeddedJpeg(data), isNull);
    });

    test('a real DNG truncated mid-file (IFD offsets now point past EOF)', () async {
      final path = '${sampleDir.path}/2026-02-15-19-37-38.dng';
      final full = await File(path).readAsBytes();
      final truncated = Uint8List.sublistView(full, 0, full.length ~/ 4);
      expect(
        DngPreviewExtractor.extractFullSizeEmbeddedJpeg(truncated),
        isNull,
      );
    });

    test('a plain JPEG (non-DNG) file is rejected without throwing', () {
      // Not a TIFF container at all: no II/MM marker.
      final data = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);
      expect(DngPreviewExtractor.extractFullSizeEmbeddedJpeg(data), isNull);
    });

    test('extractFullSizeEmbeddedJpegFromFile on a nonexistent path returns null', () async {
      final bytes = await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(
        '${sampleDir.path}/does_not_exist.dng',
      );
      expect(bytes, isNull);
    });

    test('readDngOrientation degrades to 1 for malformed input', () {
      expect(
        DngPreviewExtractor.readDngOrientation(Uint8List.fromList([1, 2])),
        1,
      );
    });
  });
}
