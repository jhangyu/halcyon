import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dart_image_loader.dart';
import 'package:halcyon_flutter/services/dng_preview_extractor.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';

void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');
  List<File> dngs() => sampleDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.dng'))
      .toList();

  test('jpeg returns its exact bytes without decoding', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader');
    addTearDown(() => dir.delete(recursive: true));
    final jpeg = File('${dir.path}/a.jpg');
    await jpeg.writeAsBytes(const [0xFF, 0xD8, 0xFF, 0xD9]); // SOI+EOI only
    final result =
        await dartImageLoad(jpeg.path, purpose: ImageRequestPurpose.preview);
    expect(result, isA<NativeImageBytes>());
    expect((result as NativeImageBytes).bytes, const [0xFF, 0xD8, 0xFF, 0xD9]);
  });

  test('preview-bearing DNGs return exactly the extractor bytes', () async {
    var covered = 0;
    for (final f in dngs()) {
      final expected =
          await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      if (expected == null) continue;
      covered++;
      final result =
          await dartImageLoad(f.path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageBytes>(), reason: f.path);
      expect((result as NativeImageBytes).bytes, expected, reason: f.path);
    }
    expect(covered, greaterThan(0), reason: 'sample set must exercise the hit path');
  });

  test('no-preview DNGs yield NeedsRawDecode with the walked orientation', () async {
    var covered = 0;
    for (final f in dngs()) {
      final full =
          await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      if (full != null) continue;
      covered++;
      final result =
          await dartImageLoad(f.path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageNeedsRawDecode>(), reason: f.path);
      final walked = await DngPreviewExtractor.readOrientation(f.path);
      expect((result as NativeImageNeedsRawDecode).exifOrientation,
          walked ?? kDefaultExifOrientation, reason: f.path);
    }
    expect(covered, greaterThan(0), reason: 'sample set must exercise the miss path');
  });

  test('sidebar purpose never returns the raw-decode signal', () async {
    for (final f in dngs()) {
      final result = await dartImageLoad(f.path,
          purpose: ImageRequestPurpose.sidebarThumbnail);
      expect(result is! NativeImageNeedsRawDecode, isTrue, reason: f.path);
    }
  });

  test('missing file is a failure, not a throw', () async {
    final result = await dartImageLoad('/nonexistent/x.dng',
        purpose: ImageRequestPurpose.preview);
    expect(result, isA<NativeImageFailure>());
  });

  test('non-DNG RAW: embedded preview is served, no-preview is an explicit'
      ' unsupported state (never the raw-decode signal)', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader_raw');
    addTearDown(() => dir.delete(recursive: true));
    var hits = 0, misses = 0;
    for (final f in dngs()) {
      final full =
          await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      final asArw = File('${dir.path}/${f.uri.pathSegments.last}.arw');
      await f.copy(asArw.path);
      final result =
          await dartImageLoad(asArw.path, purpose: ImageRequestPurpose.preview);
      if (full != null) {
        hits++;
        expect(result, isA<NativeImageBytes>(), reason: asArw.path);
      } else {
        misses++;
        expect(result, isA<NativeImageFailure>(), reason: asArw.path);
        expect((result as NativeImageFailure).code, 'RAW_NO_EMBEDDED_PREVIEW');
      }
    }
    expect(hits, greaterThan(0));
    expect(misses, greaterThan(0));
  });
}
