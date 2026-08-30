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
}
