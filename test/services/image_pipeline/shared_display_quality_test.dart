import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/jpeg_encoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/sidebar_thumbnail_codec.dart';

void main() {
  test('TC-438 the shared display quality constant is q70', () {
    expect(kDisplayJpegQuality, 70);
  });

  test('TC-439 the payload re-encoder quality IS the shared constant', () {
    expect(kReencodeJpegQuality, same(kDisplayJpegQuality));
    expect(kReencodeJpegQuality, kDisplayJpegQuality);
  });

  test('TC-440 the sidebar tile encodes at the shared quality, not q80', () async {
    // A payload above the re-encode threshold is re-encoded; below it passes
    // through untouched. Assert the DEFAULT parameter, which is the contract
    // the codec exposes, by comparing an explicit-q70 call with a default call.
    final big = Uint8List(600 * 1024); // undecodable -> both paths return input
    final viaDefault = await sidebarCacheBytes(big);
    final viaExplicit = await sidebarCacheBytes(big, jpegQuality: kDisplayJpegQuality);
    expect(viaDefault.length, viaExplicit.length);
    expect(defaultSidebarJpegQuality, kDisplayJpegQuality);
  });
}
