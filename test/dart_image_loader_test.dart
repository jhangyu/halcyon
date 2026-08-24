import 'dart:io';
import 'dart:typed_data';

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

  // M6 P3.7 (F-20): oversized-image guard — same 1.5GB decoded-pixel budget
  // the deleted native guard (AppDelegate.swift renderCGImage) enforced.
  Uint8List handcraftedOversizedTiff() {
    // Minimal little-endian TIFF: header + IFD0 with two SHORT tags,
    // ImageWidth (0x0100) and ImageLength (0x0101), both claiming 40000 —
    // 40000*40000*4 = 6.4e9 bytes, far past the 1.5e9 budget. No strips.
    final bytes = ByteData(38);
    // Header: "II", magic 42, IFD0 offset 8.
    bytes.setUint8(0, 0x49); // 'I'
    bytes.setUint8(1, 0x49); // 'I'
    bytes.setUint16(2, 42, Endian.little);
    bytes.setUint32(4, 8, Endian.little);
    // IFD0 @ offset 8: 2 entries.
    bytes.setUint16(8, 2, Endian.little);
    // Entry 0: tag 0x0100 (ImageWidth), type 3 (SHORT), count 1, value 40000.
    bytes.setUint16(10, 0x0100, Endian.little);
    bytes.setUint16(12, 3, Endian.little);
    bytes.setUint32(14, 1, Endian.little);
    bytes.setUint16(18, 40000, Endian.little);
    // Entry 1: tag 0x0101 (ImageLength), type 3 (SHORT), count 1, value 40000.
    bytes.setUint16(22, 0x0101, Endian.little);
    bytes.setUint16(24, 3, Endian.little);
    bytes.setUint32(26, 1, Endian.little);
    bytes.setUint16(30, 40000, Endian.little);
    // Next IFD offset: none.
    bytes.setUint32(34, 0, Endian.little);
    return bytes.buffer.asUint8List();
  }

  test('F-20: a header claiming a 40000x40000 decode is refused, never'
      ' handed to a raw decode', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader_oversized');
    addTearDown(() => dir.delete(recursive: true));
    final huge = File('${dir.path}/huge.dng');
    await huge.writeAsBytes(handcraftedOversizedTiff());
    final result =
        await dartImageLoad(huge.path, purpose: ImageRequestPurpose.preview);
    expect(result, isA<NativeImageFailure>());
    expect((result as NativeImageFailure).code, 'IMAGE_TOO_LARGE');
  });

  test('F-20: the guard does not fire on real, ordinary-sized samples', () async {
    expect(dngs(), isNotEmpty);
    for (final f in dngs()) {
      final result =
          await dartImageLoad(f.path, purpose: ImageRequestPurpose.preview);
      if (result is NativeImageFailure) {
        expect(result.code, isNot('IMAGE_TOO_LARGE'), reason: f.path);
      }
    }
  });
}
