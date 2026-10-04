import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';

import '../../support/synthetic_raw_containers.dart';
import '../../support/temp_dirs.dart';

// RAF / X3F container gatherers and the generic sensor-extent baseline
// (2026-10-04 preview-extraction contract D1-D4, D6).
void main() {
  late Directory dir;
  setUp(() => dir = makeTempDirSync('raw_container'));

  Future<String> write(Uint8List bytes, String name) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  Future<DngFileProbe?> probe(Uint8List bytes, String name) async =>
      DngEmbeddedJpegExtractor.probeFile(await write(bytes, name));

  Future<DngEmbeddedJpegProbe> select(
    String path,
    DngFileProbe p, {
    int? longEdge,
    int? minLongEdge,
  }) => DngEmbeddedJpegExtractor.selectAndRead(
    p,
    path: path,
    longEdge: longEdge,
    minLongEdge: minLongEdge,
    strictBitstream: true,
  );

  group('generic sensor-extent baseline (D3)', () {
    test(
      'NEF-like TIFF without DefaultCropSize: full-size selects the JPEG',
      () async {
        final path = await write(
          buildSyntheticNefLike(
            jpegWidth: 800,
            jpegHeight: 600,
            rawWidth: 828,
            rawHeight: 620,
          ),
          'z.nef',
        );
        final p = (await DngEmbeddedJpegExtractor.probeFile(path))!;
        expect(p.cropMax, 828);
        final r = await select(path, p);
        expect(r.jpeg, isNotNull);
        expect((r.jpeg!.width, r.jpeg!.height), (800, 600));
        // Same answer through the public extract API (longEdge: null).
        expect(
          await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(path),
          isNotNull,
        );
      },
    );

    test(
      'JPEG under 90% of the raw extent is still rejected for full-size',
      () async {
        final path = await write(
          buildSyntheticNefLike(
            jpegWidth: 400,
            jpegHeight: 300,
            rawWidth: 828,
            rawHeight: 620,
          ),
          'small.nef',
        );
        final p = (await DngEmbeddedJpegExtractor.probeFile(path))!;
        expect((await select(path, p)).jpeg, isNull);
        expect((await select(path, p, longEdge: 300)).jpeg, isNotNull);
      },
    );
  });

  group('RAF gatherer (D1)', () {
    test(
      'finds the header-pointed JPEG, sensor extent and orientation',
      () async {
        final bytes = buildSyntheticRaf(
          jpegWidth: 440,
          jpegHeight: 294,
          sensorWidth: 787,
          sensorHeight: 520,
          orientation: 6,
        );
        final path = await write(bytes, 'a.raf');
        final p = (await DngEmbeddedJpegExtractor.probeFile(path))!;
        expect(p.candidates.single.offset, 148);
        expect(
          (p.candidates.single.width, p.candidates.single.height),
          (440, 294),
        );
        expect(p.cropMax, 787);
        expect((p.dimensions!.width, p.dimensions!.height), (787, 520));
        expect(p.orientation, 6);
        // Full-size: 440 < 0.9 * 787 -> rejected. Preview floor 400: accepted.
        expect((await select(path, p)).jpeg, isNull);
        final r = await select(path, p, longEdge: 400, minLongEdge: 400);
        expect(r.jpeg, isNotNull);
        expect(r.malformed, isFalse);
      },
    );

    test('JPEG offset/length past EOF is unreadable, never a throw', () async {
      final p = await probe(
        buildSyntheticRaf(
          jpegWidth: 440,
          jpegHeight: 294,
          sensorWidth: 787,
          sensorHeight: 520,
          jpegLengthOverride: 0x7FFFFFFF,
        ),
        'bad.raf',
      );
      expect(p!.candidates, isEmpty);
      expect(p.unreadableCount, 1);
    });

    test('truncated RAF header yields an empty probe', () async {
      final full = buildSyntheticRaf(
        jpegWidth: 440,
        jpegHeight: 294,
        sensorWidth: 787,
        sensorHeight: 520,
      );
      final p = await probe(Uint8List.sublistView(full, 0, 90), 'trunc.raf');
      expect(p!.candidates, isEmpty);
    });
  });

  group('X3F gatherer (D2)', () {
    test(
      'finds the JPEG section; full-size accepts at >=90% of raw extent',
      () async {
        final path = await write(
          buildSyntheticX3f(
            jpegWidth: 620,
            jpegHeight: 413,
            rawCols: 666,
            rawRows: 448,
          ),
          'a.x3f',
        );
        final p = (await DngEmbeddedJpegExtractor.probeFile(path))!;
        expect(p.candidates, hasLength(1));
        expect(
          (p.candidates.single.width, p.candidates.single.height),
          (620, 413),
        );
        expect(p.cropMax, 666);
        final r = await select(path, p);
        expect(r.jpeg, isNotNull);
        expect(r.jpeg!.width, 620);
      },
    );

    test('directory offset past EOF / garbage fails cleanly', () async {
      for (final override in [0xFFFFFFFF, 0, 5]) {
        final p = await probe(
          buildSyntheticX3f(
            jpegWidth: 620,
            jpegHeight: 413,
            rawCols: 666,
            rawRows: 448,
            directoryOffsetOverride: override,
          ),
          'bad$override.x3f',
        );
        expect(p!.candidates, isEmpty, reason: 'override $override');
      }
    });
  });

  group('malformed input (D6)', () {
    test('FOVb magic with garbage body, empty file and random bytes', () async {
      final garbage = Uint8List.fromList([
        0x46, 0x4F, 0x56, 0x62, //
        for (var i = 0; i < 4096; i++) (i * 131 + 17) % 256,
      ]);
      expect((await probe(garbage, 'malformed.x3f'))!.candidates, isEmpty);
      expect(await probe(Uint8List(0), 'zero.raw'), isNull);
      final random = Uint8List.fromList([
        for (var i = 0; i < 512; i++) (i * 197 + 31) % 256,
      ]);
      expect(await probe(random, 'random.raw'), isNull);
      // The non-probe entry points stay quiet too.
      for (final n in ['malformed.x3f', 'zero.raw', 'random.raw']) {
        final miss = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          '${dir.path}/$n',
        );
        expect(miss.jpeg, isNull);
      }
    });
  });
}
