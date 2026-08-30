import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/library/photo_export_service.dart';

/// A small noisy (not flat-colour) RGBA buffer: a flat colour compresses
/// identically at any JPEG quality and would make a quality-vs-size
/// comparison vacuous.
DecodedRgba _noiseFixture({int width = 64, int height = 64}) {
  final pixels = Uint8List(width * height * 4);
  var seed = 12345;
  for (var i = 0; i < pixels.length; i += 4) {
    // Cheap deterministic PRNG -- no dependency on dart:math's Random needed.
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    pixels[i] = seed & 0xff; // R
    pixels[i + 1] = (seed >> 8) & 0xff; // G
    pixels[i + 2] = (seed >> 16) & 0xff; // B
    pixels[i + 3] = 255; // A
  }
  return DecodedRgba(rgba: pixels, width: width, height: height);
}

void main() {
  test('TC-456 the service defaults to q90 and the field is settable', () {
    final service = PhotoExportService();
    expect(service.jpegQuality, kDefaultExportJpegQuality);
    expect(kDefaultExportJpegQuality, 90);
    service.jpegQuality = 70;
    expect(service.jpegQuality, 70);
  });

  test('TC-457 quality actually reaches the encoder', () async {
    final decoded = _noiseFixture();
    final low = await exportJpegForTest(decoded, quality: 70);
    final high = await exportJpegForTest(decoded, quality: 100);
    expect(low, isNotNull);
    expect(high, isNotNull);
    expect(low!.length, lessThan(high!.length));
  });

  test('TC-470 the service defaults to the 2048 long edge and the field is '
      'settable, independently of jpegQuality', () {
    final service = PhotoExportService();
    expect(service.longEdge, kDefaultExportLongEdge);
    expect(kDefaultExportLongEdge, 2048);
    service.longEdge = 480;
    expect(service.longEdge, 480);
    expect(service.jpegQuality, kDefaultExportJpegQuality,
        reason: 'setting longEdge must not disturb jpegQuality');
  });

  test('TC-471 kExportLongEdgeStops has exactly the 8 named round-2 stops, '
      'Original (sentinel 0) last', () {
    expect(kExportLongEdgeStops,
        [480, 720, 1080, 1440, 2048, 2560, 3840, 0]);
    expect(kOriginalExportLongEdge, 0);
  });

  test('TC-472 exportLongEdgeLabel formats every stop, Original spelled out',
      () {
    expect(exportLongEdgeLabel(480), '480px');
    expect(exportLongEdgeLabel(2048), '2048px');
    expect(exportLongEdgeLabel(3840), '3840px');
    expect(exportLongEdgeLabel(kOriginalExportLongEdge), 'Original');
  });

  test('TC-476b the service defaults to JPEG filetype and the field is '
      'settable, independently of quality/longEdge', () {
    final service = PhotoExportService();
    expect(service.filetype, kDefaultExportFiletype);
    expect(kDefaultExportFiletype, ExportFiletype.jpeg);
    service.filetype = ExportFiletype.webpLossy;
    expect(service.filetype, ExportFiletype.webpLossy);
    expect(service.jpegQuality, kDefaultExportJpegQuality);
    expect(service.longEdge, kDefaultExportLongEdge);
  });

  test('TC-477b exactly JPEG and WebP(lossy) are available -- HEIF and '
      'WebP(lossless) are NOT, per the round-2b ceyx feasibility finding',
      () {
    expect(ExportFiletype.jpeg.available, isTrue);
    expect(ExportFiletype.webpLossy.available, isTrue);
    expect(ExportFiletype.heif.available, isFalse);
    expect(ExportFiletype.webpLossless.available, isFalse);
  });

  test('TC-478 every filetype has the correct output extension', () {
    expect(ExportFiletype.jpeg.extension, 'jpg');
    expect(ExportFiletype.heif.extension, 'heic');
    expect(ExportFiletype.webpLossy.extension, 'webp');
    expect(ExportFiletype.webpLossless.extension, 'webp');
  });
}
