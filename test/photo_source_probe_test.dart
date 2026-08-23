// Real samples only, per repo red line: local_data/photo_samples/.
// The whole point of the probe is that it reads CONTENT, so a synthetic
// fixture would only test the parser, not the claim.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/photo_source.dart';

void main() {
  final dngDir = Directory('local_data/photo_samples/DNG');
  final jpgDir = Directory('local_data/photo_samples/JPG');
  final hasSamples = dngDir.existsSync();

  List<File> dngs() =>
      dngDir.listSync().whereType<File>().where(
        (f) => f.path.toLowerCase().endsWith('.dng'),
      ).toList()..sort((a, b) => a.path.compareTo(b.path));

  // The display window this pipeline actually asks for.
  const windowLongEdge = 2800;

  group('PhotoSource.probe (M3 cost gate)', () {
    // THE KILLER for the entire cost-gate premise. The pre-M3 rule was "a
    // .dng needs an expensive RAW decode", and the design's central
    // measurement is that this is wrong 13 times in 14. Both halves are
    // asserted by NAME, so neither a probe that answers `expensive` for
    // everything (the old behaviour, which would still "work") nor one that
    // answers `cheap` for everything (which would strand the no-preview file
    // in a 9-wide decode storm) can pass.
    test('TC-072 content, not the extension, decides the rung: the SAME '
        'extension yields both answers', () async {
      final withPreview = File('${dngDir.path}/2026-02-15-19-37-38.dng');
      final withoutPreview = File('${dngDir.path}/IMG_20251112_092839.dng');
      expect(withPreview.existsSync(), isTrue, reason: 'sample missing');
      expect(withoutPreview.existsSync(), isTrue, reason: 'sample missing');

      expect(
        await PhotoSource.probe(withPreview.path, longEdge: windowLongEdge),
        SourceCost.cheap,
        reason: 'this .dng carries a full-size embedded JPEG; charging it a '
            'RAW decode is the 13-in-14 error M3 exists to fix',
      );
      expect(
        await PhotoSource.probe(withoutPreview.path, longEdge: windowLongEdge),
        SourceCost.expensive,
        reason: 'this .dng has no usable embedded JPEG -- promoting it to the '
            'cheap rung puts nine FFI decodes in flight at once',
      );
    }, skip: hasSamples ? null : 'no local samples');

    test('TC-073 every sample DNG is measured, and exactly the known '
        'preview-less ones are expensive', () async {
      // The expected set is written out in full rather than derived. Deriving
      // it from the probe's own answers would be circular and assert nothing;
      // a count alone would not notice one expensive sample being swapped for
      // another. These fixtures exist to make sample-set drift fail LOUDLY,
      // and the literal is the loudest shape available.
      //
      // The thirteen below were each measured to have NO usable embedded JPEG:
      // largestLongEdge 0 (not merely under the window) and a full extraction
      // returning nothing. Corroborated OUTSIDE our own walker by exiftool:
      // the 2024-07-* dozen are Xiaomi 2304FPN6DC phone DNGs whose IFD0 is a
      // JPEG-compressed Color Filter Array -- a Bayer mosaic, not a
      // displayable preview -- with no preview/thumbnail/JpgFromRaw tag
      // anywhere. They are the [U-3]/AC8 samples the user supplied.
      //
      // Do NOT re-derive this list from file mtimes: several of the 2024-07-*
      // files carry 2024 timestamps despite being the newest additions.
      const knownPreviewLess = [
        '2024-07-03-18-52-26.dng',
        '2024-07-03-18-52-41.dng',
        '2024-07-03-18-52-49.dng',
        '2024-07-03-18-54-44.dng',
        '2024-07-03-18-54-49.dng',
        '2024-07-03-18-55-14.dng',
        '2024-07-03-18-55-35.dng',
        '2024-07-03-18-56-59.dng',
        '2024-07-03-18-58-42.dng',
        '2024-07-03-19-03-09.dng',
        '2024-07-06-19-09-52.dng',
        '2024-07-06-19-09-55.dng',
        'IMG_20251112_092839.dng',
      ];

      final all = dngs();
      expect(
        all.length,
        26,
        reason: 'a sample appearing or vanishing must fail here first, before '
            'it silently changes what every other probe test measures',
      );

      final expensive = <String>[];
      for (final file in all) {
        final cost = await PhotoSource.probe(
          file.path,
          longEdge: windowLongEdge,
        );
        expect(cost, isNotNull, reason: '${file.path} could not be measured');
        if (cost == SourceCost.expensive) {
          expensive.add(file.uri.pathSegments.last);
        }
      }
      expect(expensive, knownPreviewLess);
      expect(
        expensive.length,
        13,
        reason: 'AC8 needs at least 9 real no-preview DNGs; this is the '
            'measurement that says how many we actually have',
      );
    }, skip: hasSamples ? null : 'no local samples');

    test('TC-074 the SAME file changes rung when the requested size changes',
        () async {
      // The rung is a function of (content, requested size), not of the file
      // alone. This sample's largest embedded candidate is 6000px, so it
      // satisfies a window request and cannot satisfy a bigger one. A probe
      // that ignored longEdge -- an easy simplification, since 13 of 14
      // samples answer `cheap` either way -- gives the same answer twice and
      // dies here.
      final file = File('${dngDir.path}/2026-02-15-19-37-38.dng');
      expect(
        await PhotoSource.probe(file.path, longEdge: 2800),
        SourceCost.cheap,
      );
      expect(
        await PhotoSource.probe(file.path, longEdge: 8000),
        SourceCost.expensive,
        reason: 'no embedded candidate reaches 8000px, so producing one means '
            'a real decode -- regardless of the file carrying a preview',
      );
    }, skip: hasSamples ? null : 'no local samples');

    test('TC-075 probing costs at most 300KB of reads, and a JPEG costs 2 '
        'bytes', () async {
      for (final file in dngs()) {
        var read = 0;
        await PhotoSource.probe(
          file.path,
          longEdge: windowLongEdge,
          onDiskRead: (n) => read += n,
        );
        expect(
          read,
          lessThan(300 * 1024),
          reason: '${file.path}: the probe must never fall back to reading '
              'the whole file -- at 7.5MB average that is the exact hazard '
              'M0 removed',
        );
      }

      final jpg = jpgDir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.toLowerCase().endsWith('.jpg'));
      var jpgRead = 0;
      final cost = await PhotoSource.probe(
        jpg.path,
        longEdge: windowLongEdge,
        onDiskRead: (n) => jpgRead += n,
      );
      expect(cost, SourceCost.cheap);
      expect(
        jpgRead,
        2,
        reason: 'the JPEG hot path must stay free: two bytes of magic and out '
            '(design section 5). Any IFD walk here is Dart CPU on the '
            "app's most-used path",
      );
    }, skip: hasSamples ? null : 'no local samples');

    test('TC-076 an unmeasurable file is UNDETERMINED, not expensive', () async {
      expect(
        await PhotoSource.probe(
          '/tmp/halcyon-no-such-file.dng',
          longEdge: windowLongEdge,
        ),
        isNull,
        reason: 'null and expensive must stay distinct: the caller resolves '
            'the undetermined case from the first bridge answer instead of '
            'guessing a rung (frozen contract A-section-2)',
      );
    });
  });
}
