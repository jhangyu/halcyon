import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/supported_photo_formats.dart';

/// D2 sibling-format ranking (user ruling, 2026-08-28 parking-lot remediation).
///
/// Cheap tier order is JPG > HEIC > WebP > PNG, and a TIFF is classified
/// cheap/expensive by probing for an embedded already-rendered image. These
/// tests pin both.
void main() {
  File f(String name) => File('/x/$name');

  group('TC-332: cheap-tier sibling ranking JPG > HEIC > WebP > PNG', () {
    // Each adjacent pair is asserted with the higher-ranked file listed LAST,
    // so a naive "first supported file" fallback would return the wrong one —
    // only a correct ranking passes.
    test('JPG beats HEIC', () {
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.heic'), f('a.jpg')])!.path,
        '/x/a.jpg',
      );
    });

    test('HEIC beats WebP', () {
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.webp'), f('a.heic')])!.path,
        '/x/a.heic',
      );
    });

    test('WebP beats PNG', () {
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.png'), f('a.webp')])!.path,
        '/x/a.webp',
      );
    });

    test('full order holds when all four are present, regardless of list order',
        () {
      final files = [f('a.png'), f('a.webp'), f('a.heic'), f('a.jpg')];
      expect(SupportedPhotoFormats.bestFileToLoad(files)!.path, '/x/a.jpg');
      expect(
        SupportedPhotoFormats.bestFileToLoad([
          f('a.png'),
          f('a.webp'),
          f('a.heic'),
        ])!.path,
        '/x/a.heic',
      );
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.png'), f('a.webp')])!.path,
        '/x/a.webp',
      );
    });

    // Codec expansion (2026-08-30, ruling Q6): AVIF and JXL were inserted
    // between WebP and PNG -- jpg > heic > webp > avif > jxl, png last.
    test(
        'the exact preferredLoadExtensions order is '
        'JPG,JPEG,HEIC,HEIF,WebP,AVIF,JXL,PNG', () {
      expect(SupportedPhotoFormats.preferredLoadExtensions, <String>[
        '.jpg',
        '.jpeg',
        '.heic',
        '.heif',
        '.webp',
        '.avif',
        '.jxl',
        '.png',
      ]);
    });

    test('every cheap-tier sibling still beats a DNG/RAW sibling', () {
      for (final cheap in ['a.jpg', 'a.heic', 'a.webp', 'a.png']) {
        expect(
          SupportedPhotoFormats.bestFileToLoad([f('a.dng'), f(cheap)])!.path,
          '/x/$cheap',
          reason: '$cheap must outrank a RAW sibling',
        );
      }
    });
  });

  group('TC-333: TIFF cheap/expensive decided by embedded-preview probe', () {
    Future<bool> yes(String _) async => true;
    Future<bool> no(String _) async => false;

    test('TIFF WITH an embedded rendered image ranks above a DNG sibling '
        '(cheap tier, after PNG)', () async {
      final chosen = await SupportedPhotoFormats.resolveBestFileToLoad(
        [f('a.dng'), f('a.tif')],
        probe: yes,
      );
      expect(chosen!.path, '/x/a.tif');
    });

    test('TIFF WITHOUT an embedded rendered image stays expensive; the DNG '
        'sibling is returned by the fallback', () async {
      final chosen = await SupportedPhotoFormats.resolveBestFileToLoad(
        [f('a.dng'), f('a.tif')],
        probe: no,
      );
      expect(chosen!.path, '/x/a.dng');
    });

    test('a cheap-extension sibling wins without ever probing the TIFF',
        () async {
      var probed = false;
      final chosen = await SupportedPhotoFormats.resolveBestFileToLoad(
        [f('a.tif'), f('a.jpg')],
        probe: (_) async {
          probed = true;
          return true;
        },
      );
      expect(chosen!.path, '/x/a.jpg');
      expect(probed, isFalse, reason: 'the probe must not run once JPG won');
    });

    test('a lone TIFF is returned without probing (probe cannot change it)',
        () async {
      var probed = false;
      final chosen = await SupportedPhotoFormats.resolveBestFileToLoad(
        [f('a.tif')],
        probe: (_) async {
          probed = true;
          return false;
        },
      );
      expect(chosen!.path, '/x/a.tif');
      expect(probed, isFalse);
    });
  });
}
