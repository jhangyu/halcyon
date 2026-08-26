import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';

/// F3 copy-semantics regression (round-2 F3, user decision 2026-08-23: FIX).
///
/// Pre-M0 base 48bb934's `_MemorySource.read` returned `sublist` (an
/// independent copy). The M0 rewrite switched to `Uint8List.sublistView`,
/// which is a VIEW into the caller's buffer: mutating the caller's buffer
/// after the call mutates the "returned" bytes too, and pins the whole
/// source buffer (up to ~25 MB for a DNG) alive for as long as the result is
/// held -- a live defect the moment a caller caches the result (M3).
///
/// This test is the named killer for view semantics: it calls the in-memory
/// API, captures the returned bytes, mutates the ORIGINAL source buffer, and
/// asserts the returned bytes are unaffected. Under view semantics this is a
/// content assertion failure, not a compile error.
void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');

  // Orientation 1 (per dng_embedded_jpeg_extractor_long_edge_selection_test.dart AC2), so the
  // returned bytes are exactly the `_MemorySource.read` slice with no
  // `_injectExifOrientation` rebuild in the way.
  const sampleName = '2026-02-15-19-37-38.dng';

  test(
    'AC-B1: extractFullSizeEmbeddedJpeg result is unaffected by mutating '
    'the source buffer after the call',
    () async {
      final path = '${sampleDir.path}/$sampleName';
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');

      final original = await File(path).readAsBytes();
      // Mutable copy: File.readAsBytes may already return a fresh buffer,
      // but we need one we are free to mutate in place regardless.
      final data = Uint8List.fromList(original);

      final result = DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data);
      expect(result, isNotNull, reason: '$sampleName expected a full-size embedded preview');

      // Snapshot the expected content BEFORE mutating the source.
      final expectedBytes = Uint8List.fromList(result!);

      // Mutate the entire source buffer in place.
      data.fillRange(0, data.length, 0xAA);

      expect(
        result.length,
        expectedBytes.length,
        reason: 'result length must not change after source mutation',
      );
      expect(
        result,
        expectedBytes,
        reason:
            'returned bytes changed after the source buffer was mutated -- '
            'the extractor is returning a VIEW into the caller\'s buffer '
            'instead of an independent copy',
      );
    },
  );
}
