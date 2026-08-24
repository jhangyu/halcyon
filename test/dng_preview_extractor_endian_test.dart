import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/dng_preview_extractor.dart';

import 'support/synthetic_dng.dart';

// M7 Task 1 (audit gap 5). `_detectByteOrder` / `_readerFor` claim big-endian
// support, but before this file no `MM` input existed anywhere in test/ -- the
// entire big-endian branch was unexercised code.
//
// The assertions are DIFFERENTIAL on purpose: the same logical container is
// built twice, once `II` and once `MM`, and the extractor must return
// identical results for both. Asserting absolute values instead would let a
// wrong-but-internally-consistent reader pass.

void main() {
  const candidates = <SyntheticCandidate>[
    SyntheticCandidate(width: 400, height: 300),
    SyntheticCandidate(width: 1600, height: 1200),
  ];
  const orientation = 6;

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('halcyon_endian_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
  });

  Future<({String little, String big})> writePair() async {
    final little = await writeSyntheticDng(
      buildSyntheticDng(candidates: candidates, orientation: orientation),
      dir: tmp,
      name: 'little.dng',
    );
    final big = await writeSyntheticDng(
      buildSyntheticDng(
        candidates: candidates,
        orientation: orientation,
        bigEndian: true,
      ),
      dir: tmp,
      name: 'big.dng',
    );
    return (little: little, big: big);
  }

  group('synthetic_dng helper', () {
    test('is deterministic: identical arguments give identical bytes', () {
      final a = buildSyntheticDng(
        candidates: candidates,
        orientation: orientation,
      );
      final b = buildSyntheticDng(
        candidates: candidates,
        orientation: orientation,
      );
      expect(a, equals(b));

      final bigA = buildSyntheticDng(candidates: candidates, bigEndian: true);
      final bigB = buildSyntheticDng(candidates: candidates, bigEndian: true);
      expect(bigA, equals(bigB));
    });

    test('writes the requested byte-order marker', () {
      final little = buildSyntheticDng(candidates: candidates);
      final big = buildSyntheticDng(candidates: candidates, bigEndian: true);
      expect([little[0], little[1]], equals([0x49, 0x49]));
      expect([big[0], big[1]], equals([0x4D, 0x4D]));
      // Same logical content, different encoding: the containers must not be
      // byte-identical, otherwise the differential test below proves nothing.
      expect(little, isNot(equals(big)));
      expect(little.length, equals(big.length));
    });

    test(
      'the II build is readable at all (differential sanity floor)',
      () async {
        final paths = await writePair();
        final result = await DngPreviewExtractor.extractEmbeddedJpeg(
          paths.little,
          longEdge: null,
        );
        expect(
          result,
          isNotNull,
          reason:
              'the helper must produce a container the extractor accepts, '
              'or MM == II would hold trivially by both being null',
        );
      },
    );
  });

  group('MM equals II', () {
    test('selected dims at longEdge: 200', () async {
      final paths = await writePair();
      final little = await DngPreviewExtractor.extractEmbeddedJpeg(
        paths.little,
        longEdge: 200,
      );
      final big = await DngPreviewExtractor.extractEmbeddedJpeg(
        paths.big,
        longEdge: 200,
      );
      expect(little, isNotNull);
      expect(big, isNotNull);
      expect(big!.width, equals(little!.width));
      expect(big.height, equals(little.height));
    });

    test('selected dims at longEdge: null', () async {
      final paths = await writePair();
      final little = await DngPreviewExtractor.extractEmbeddedJpeg(
        paths.little,
        longEdge: null,
      );
      final big = await DngPreviewExtractor.extractEmbeddedJpeg(
        paths.big,
        longEdge: null,
      );
      expect(little, isNotNull);
      expect(big, isNotNull);
      expect(big!.width, equals(little!.width));
      expect(big.height, equals(little.height));
      // The two selection modes must disagree, otherwise the longEdge: 200
      // assertion above is a duplicate of this one.
      expect(big.width, isNot(equals(400)));
    });

    test('extracted bytes are byte-identical', () async {
      final paths = await writePair();
      final little = await DngPreviewExtractor.extractEmbeddedJpeg(
        paths.little,
        longEdge: null,
      );
      final big = await DngPreviewExtractor.extractEmbeddedJpeg(
        paths.big,
        longEdge: null,
      );
      expect(little, isNotNull);
      expect(big, isNotNull);
      expect(big!.bytes, isA<Uint8List>());
      expect(big.bytes, equals(little!.bytes));
    });

    test('orientation matches', () async {
      final paths = await writePair();
      final little = await DngPreviewExtractor.readOrientation(paths.little);
      final big = await DngPreviewExtractor.readOrientation(paths.big);
      expect(little, equals(orientation));
      expect(big, equals(little));
    });
  });

  group('corruptOffsets', () {
    test('stays walkable but yields no extractable candidate', () async {
      final little = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: candidates,
          orientation: orientation,
          corruptOffsets: true,
        ),
        dir: tmp,
        name: 'corrupt_little.dng',
      );
      final big = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: candidates,
          orientation: orientation,
          bigEndian: true,
          corruptOffsets: true,
        ),
        dir: tmp,
        name: 'corrupt_big.dng',
      );
      // Structurally walkable: IFD0 still parses, so orientation still reads.
      expect(
        await DngPreviewExtractor.readOrientation(little),
        equals(orientation),
      );
      expect(
        await DngPreviewExtractor.readOrientation(big),
        equals(orientation),
      );
      // ...but every declared candidate points past EOF. This is Task 3's
      // malformed input; today both byte orders agree on "nothing extractable".
      expect(
        await DngPreviewExtractor.extractEmbeddedJpeg(little, longEdge: null),
        isNull,
      );
      expect(
        await DngPreviewExtractor.extractEmbeddedJpeg(big, longEdge: null),
        isNull,
      );
    });
  });
}
