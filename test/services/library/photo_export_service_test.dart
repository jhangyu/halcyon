import 'dart:io';

import 'package:exif/exif.dart' as pkg_exif;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';
import 'package:halcyon_flutter/services/image_pipeline/exif_orientation.dart';
import 'package:halcyon_flutter/services/library/photo_export_service.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

Uint8List _fakeJpeg(String tag) => Uint8List.fromList('jpeg:$tag'.codeUnits);

// Real samples per repo red line (photos only from local_data/photo_samples).
final _sampleDir = Directory('local_data/photo_samples/DNG');
List<File> _dngs() => _sampleDir
    .listSync()
    .whereType<File>()
    .where((f) => f.path.toLowerCase().endsWith('.dng'))
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('halcyon_export_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  PhotoItem starred(String id, List<String> filenames) {
    return PhotoItem(
      id: id,
      status: PhotoStatus.starred,
      files: filenames.map((name) => File(p.join(tempDir.path, name))).toList(),
    );
  }

  PhotoItem unstarred(String id, List<String> filenames, PhotoStatus status) {
    return PhotoItem(
      id: id,
      status: status,
      files: filenames.map((name) => File(p.join(tempDir.path, name))).toList(),
    );
  }

  test('only starred items are exported; unmarked/trashed are not', () async {
    final destDir = Directory(p.join(tempDir.path, 'out'));
    await destDir.create();

    final items = [
      starred('a', ['a.jpg']),
      unstarred('b', ['b.jpg'], PhotoStatus.unmarked),
      unstarred('c', ['c.jpg'], PhotoStatus.trashed),
    ];

    final service = PhotoExportService(
      fetchBytes: (path) async => _fakeJpeg(p.basename(path)),
    );

    final outcome = await service.exportStarred(items, destDir);

    expect(outcome.exportedCount, 1);
    expect(outcome.failures, isEmpty);
    expect(await File(p.join(destDir.path, 'a.jpg')).exists(), isTrue);
    expect(await File(p.join(destDir.path, 'b.jpg')).exists(), isFalse);
    expect(await File(p.join(destDir.path, 'c.jpg')).exists(), isFalse);
  });

  test(
    'an item with .dng + .jpg siblings produces exactly one output file, '
    'from the JPEG source',
    () async {
      final destDir = Directory(p.join(tempDir.path, 'out'));
      await destDir.create();

      final requestedPaths = <String>[];
      final items = [
        starred('IMG_0001', ['IMG_0001.dng', 'IMG_0001.jpg']),
      ];

      final service = PhotoExportService(
        fetchBytes: (path) async {
          requestedPaths.add(path);
          return _fakeJpeg(p.basename(path));
        },
      );

      final outcome = await service.exportStarred(items, destDir);

      expect(outcome.exportedCount, 1);
      expect(requestedPaths, hasLength(1));
      expect(requestedPaths.single, endsWith('IMG_0001.jpg'));
      final outFiles = destDir.listSync();
      expect(outFiles, hasLength(1));
      expect(p.basename(outFiles.single.path), 'IMG_0001.jpg');
    },
  );

  test('an existing destination file is overwritten', () async {
    final destDir = Directory(p.join(tempDir.path, 'out'));
    await destDir.create();
    final outFile = File(p.join(destDir.path, 'a.jpg'));
    await outFile.writeAsBytes([0, 0, 0]);

    final items = [
      starred('a', ['a.jpg']),
    ];
    final service = PhotoExportService(
      fetchBytes: (path) async => _fakeJpeg('new'),
    );

    final outcome = await service.exportStarred(items, destDir);

    expect(outcome.exportedCount, 1);
    expect(await outFile.readAsBytes(), _fakeJpeg('new'));
  });

  test(
    'a fetch that returns null or throws lands in failures and the '
    'remaining items still export',
    () async {
      final destDir = Directory(p.join(tempDir.path, 'out'));
      await destDir.create();

      final items = [
        starred('a', ['a.jpg']),
        starred('b', ['b.jpg']),
        starred('c', ['c.jpg']),
      ];

      final service = PhotoExportService(
        fetchBytes: (path) async {
          if (path.endsWith('a.jpg')) return null;
          if (path.endsWith('b.jpg')) {
            throw Exception('native decode failed');
          }
          return _fakeJpeg('c');
        },
      );

      final outcome = await service.exportStarred(items, destDir);

      expect(outcome.exportedCount, 1);
      expect(outcome.failures, hasLength(2));
      expect(outcome.failures.any((f) => f.startsWith('a.jpg:')), isTrue);
      expect(outcome.failures.any((f) => f.startsWith('b.jpg:')), isTrue);
      expect(await File(p.join(destDir.path, 'c.jpg')).exists(), isTrue);
    },
  );

  test(
    'onProgress is called once per item with a monotonically increasing '
    'done and the correct total',
    () async {
      final destDir = Directory(p.join(tempDir.path, 'out'));
      await destDir.create();

      final items = List.generate(
        6,
        (i) => starred('item$i', ['item$i.jpg']),
      );

      final service = PhotoExportService(
        fetchBytes: (path) async => _fakeJpeg(path),
      );

      final progressCalls = <List<int>>[];
      final outcome = await service.exportStarred(
        items,
        destDir,
        onProgress: (done, total) => progressCalls.add([done, total]),
      );

      expect(outcome.exportedCount, 6);
      expect(progressCalls, hasLength(6));
      expect(progressCalls.every((c) => c[1] == 6), isTrue);
      final doneValues = progressCalls.map((c) => c[0]).toList();
      final sortedDoneValues = [...doneValues]..sort();
      expect(
        doneValues,
        sortedDoneValues,
        reason: 'done must be monotonically increasing',
      );
      expect(doneValues, [1, 2, 3, 4, 5, 6]);
    },
  );

  test('a destination that does not exist returns an empty outcome without throwing', () async {
    final destDir = Directory(p.join(tempDir.path, 'does_not_exist'));

    final items = [
      starred('a', ['a.jpg']),
    ];
    final service = PhotoExportService(
      fetchBytes: (path) async => _fakeJpeg('x'),
    );

    final outcome = await service.exportStarred(items, destDir);

    expect(outcome.exportedCount, 0);
    expect(outcome.failures, isEmpty);
  });

  // M6 P3.6 (F-11): default export byte source is decode -> resize -> encode
  // in pure Dart (exportBytesFor), not the halcyon/thumbnail channel. This is
  // the Appendix-B rewrite of this file's default-fetch case (the seam it
  // exercises changed: ExportBytesFetch's DEFAULT implementation moved off
  // the channel; the typedef signature itself is unchanged).
  group('default fetch (no fetchBytes injected): pure-Dart export pipeline', () {
    const thumbnailChannel = MethodChannel('halcyon/thumbnail');

    setUp(() {
      // Proves the default path never reaches the channel (AC of this task):
      // any call is a hard failure of the test, not a silent fallback.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(thumbnailChannel, (call) async {
        throw MissingPluginException(
          'halcyon/thumbnail must not be reached by the default export path',
        );
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(thumbnailChannel, null);
    });

    test(
      'a preview-bearing DNG exports a JPEG with long edge <= 2048, no '
      'channel call',
      () async {
        final samples = _dngs();
        File? withPreview;
        for (final f in samples) {
          if (await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
                f.path,
              ) !=
              null) {
            withPreview = f;
            break;
          }
        }
        expect(withPreview, isNotNull,
            reason: 'sample set must include a preview-bearing DNG');

        final destDir = Directory(p.join(tempDir.path, 'out'));
        await destDir.create();
        // Construct the item directly (not via the `starred` helper, which
        // joins filenames under tempDir.path) so the item's file stays the
        // real sample's absolute path.
        final items = [
          PhotoItem(
            id: 'sample',
            status: PhotoStatus.starred,
            files: [File(withPreview!.path)],
          ),
        ];

        final service = PhotoExportService();
        final outcome = await service.exportStarred(items, destDir);

        expect(outcome.failures, isEmpty);
        expect(outcome.exportedCount, 1);
        final outFile = File(
          p.join(
            destDir.path,
            '${p.basenameWithoutExtension(withPreview.path)}.jpg',
          ),
        );
        expect(await outFile.exists(), isTrue);
        final decoded = img.decodeJpg(await outFile.readAsBytes());
        expect(decoded, isNotNull);
        expect(decoded!.width <= 2048 && decoded.height <= 2048, isTrue,
            reason: 'long edge must be capped at 2048');
      },
    );

    test(
      'a no-preview DNG with an injected decoder exports via the raw-decode '
      'branch, no channel call',
      () async {
        final samples = _dngs();
        File? noPreview;
        for (final f in samples) {
          if (await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
                f.path,
              ) ==
              null) {
            noPreview = f;
            break;
          }
        }
        expect(noPreview, isNotNull,
            reason: 'sample set must include a no-preview DNG');

        final destDir = Directory(p.join(tempDir.path, 'out'));
        await destDir.create();
        final items = [
          PhotoItem(
            id: 'sample',
            status: PhotoStatus.starred,
            files: [File(noPreview!.path)],
          ),
        ];

        Future<DecodedRgba> fakeDecoder(String path) async {
          // 4x2, two solid colours (red left half, blue right half) so an
          // orientation bug would be visible if this test asserted pixels;
          // here we assert only that a valid JPEG comes out.
          final width = 4, height = 2;
          final rgba = Uint8List(width * height * 4);
          for (var y = 0; y < height; y++) {
            for (var x = 0; x < width; x++) {
              final i = (y * width + x) * 4;
              final isLeft = x < width ~/ 2;
              rgba[i] = isLeft ? 255 : 0;
              rgba[i + 1] = 0;
              rgba[i + 2] = isLeft ? 0 : 255;
              rgba[i + 3] = 255;
            }
          }
          return DecodedRgba(rgba: rgba, width: width, height: height);
        }

        final service = PhotoExportService(decoder: fakeDecoder);
        final outcome = await service.exportStarred(items, destDir);

        expect(outcome.failures, isEmpty);
        expect(outcome.exportedCount, 1);
        final outFile = File(
          p.join(
            destDir.path,
            '${p.basenameWithoutExtension(noPreview.path)}.jpg',
          ),
        );
        final decoded = img.decodeJpg(await outFile.readAsBytes());
        expect(decoded, isNotNull);
      },
    );

    test(
      'a no-preview DNG with NO decoder injected fails the item, no crash, '
      'no channel call',
      () async {
        final samples = _dngs();
        File? noPreview;
        for (final f in samples) {
          if (await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
                f.path,
              ) ==
              null) {
            noPreview = f;
            break;
          }
        }
        expect(noPreview, isNotNull);

        final destDir = Directory(p.join(tempDir.path, 'out'));
        await destDir.create();
        final items = [
          PhotoItem(
            id: 'sample',
            status: PhotoStatus.starred,
            files: [File(noPreview!.path)],
          ),
        ];

        final service = PhotoExportService();
        final outcome = await service.exportStarred(items, destDir);

        expect(outcome.exportedCount, 0);
        expect(outcome.failures, hasLength(1));
      },
    );
  });

  // M6 P3 review (task #6), P-14 ruling: exported JPEGs must carry the
  // source file's EXIF metadata again, with Orientation forced to 1. This
  // promotes the reviewer's throwaway probe
  // (scripts/tmp/m6-r1-verify/export_exif_probe_test.dart) into a permanent
  // regression test. The fixture is self-validating: it reads the source
  // DNG's own EXIF via pkg:exif first, so the assertions are pinned against
  // whatever that DNG actually carries, not a hard-coded guess.
  group('exportBytesFor: source EXIF carry-over (P3 review P-14 ruling)', () {
    test(
      'export of a DNG with source Make/Model/DateTimeOriginal EXIF carries '
      'those tags into the output JPEG, with Orientation forced to 1',
      () async {
        final samples = _dngs();
        File? withExif;
        Map<String, pkg_exif.IfdTag>? sourceTags;
        for (final f in samples) {
          final tags = await pkg_exif.readExifFromFile(f);
          final make = tags['Image Make']?.printable.trim();
          final model = tags['Image Model']?.printable.trim();
          final dateTimeOriginal =
              tags['EXIF DateTimeOriginal']?.printable.trim();
          if ((make?.isNotEmpty ?? false) &&
              (model?.isNotEmpty ?? false) &&
              (dateTimeOriginal?.isNotEmpty ?? false)) {
            withExif = f;
            sourceTags = tags;
            break;
          }
        }
        expect(
          withExif,
          isNotNull,
          reason: 'sample set must include a DNG with Make/Model/'
              'DateTimeOriginal EXIF',
        );

        final exported =
            await PhotoExportService.exportBytesFor(withExif!.path);
        expect(exported, isNotNull);

        final outImage = img.decodeJpg(exported!);
        expect(outImage, isNotNull);
        final exif = outImage!.exif;

        expect(
          exif.isEmpty,
          isFalse,
          reason: 'exported JPEG must carry source EXIF metadata',
        );
        expect(
          exif.imageIfd['Make']?.toString(),
          sourceTags!['Image Make']!.printable.trim(),
        );
        expect(
          exif.imageIfd['Model']?.toString(),
          sourceTags['Image Model']!.printable.trim(),
        );
        expect(
          exif.exifIfd['DateTimeOriginal']?.toString(),
          sourceTags['EXIF DateTimeOriginal']!.printable.trim(),
        );

        // Orientation must be verified via an INDEPENDENT oracle
        // (pkg:exif reading the raw output bytes), not via
        // `img.decodeJpg`/`outImage.exif`: the `image` package's own JPEG
        // decoder unconditionally clears the Orientation tag on every decode
        // (`getImageFromJpeg`/`_jpeg_quantize_io.dart:225`,
        // `..exif.imageIfd.orientation = null`) because it always bakes
        // orientation into pixel layout -- so `outImage.exif` can never show
        // Orientation regardless of what bytes were actually written. This
        // is a decode-time package behaviour, not something under this
        // service's control.
        final outputTags = await pkg_exif.readExifFromBytes(exported);
        expect(
          outputTags['Image Orientation']?.values.firstAsInt(),
          1,
          reason: 'orientation must be forced to 1 in the exported bytes',
        );
      },
    );
  });

  // M6 P3.6 (F-11): the 8-case EXIF orientation mapping applied to raw
  // (unrotated) FFI decode output. A 2x1 two-colour image makes a wrong
  // rotate/flip choice visible via pixel position.
  group('bakeExifOnDecoded: all 8 EXIF orientation values', () {
    img.Image twoByOne() {
      final image = img.Image(width: 2, height: 1, numChannels: 4);
      image.setPixelRgba(0, 0, 255, 0, 0, 255); // left = red
      image.setPixelRgba(1, 0, 0, 0, 255, 255); // right = blue
      return image;
    }

    (int, int, int, int) rgbaAt(img.Image image, int x, int y) {
      final px = image.getPixel(x, y);
      return (px.r.toInt(), px.g.toInt(), px.b.toInt(), px.a.toInt());
    }

    const red = (255, 0, 0, 255);
    const blue = (0, 0, 255, 255);

    test('orientation 1: identity', () {
      final out = bakeExifOnDecoded(twoByOne(), 1);
      expect(out.width, 2);
      expect(out.height, 1);
      expect(rgbaAt(out, 0, 0), red);
      expect(rgbaAt(out, 1, 0), blue);
    });

    test('orientation 2: flip horizontal', () {
      final out = bakeExifOnDecoded(twoByOne(), 2);
      expect(out.width, 2);
      expect(out.height, 1);
      expect(rgbaAt(out, 0, 0), blue);
      expect(rgbaAt(out, 1, 0), red);
    });

    test('orientation 3: rotate 180', () {
      final out = bakeExifOnDecoded(twoByOne(), 3);
      expect(out.width, 2);
      expect(out.height, 1);
      expect(rgbaAt(out, 0, 0), blue);
      expect(rgbaAt(out, 1, 0), red);
    });

    test('orientation 4: flip vertical (no-op on a 1-row image, colours'
        ' unchanged)', () {
      final out = bakeExifOnDecoded(twoByOne(), 4);
      expect(out.width, 2);
      expect(out.height, 1);
      expect(rgbaAt(out, 0, 0), red);
      expect(rgbaAt(out, 1, 0), blue);
    });

    test('orientation 5: transpose (rotate 90 + flip horizontal)', () {
      final out = bakeExifOnDecoded(twoByOne(), 5);
      expect(out.width, 1);
      expect(out.height, 2);
      expect(rgbaAt(out, 0, 0), red);
      expect(rgbaAt(out, 0, 1), blue);
    });

    test('orientation 6: rotate 90 CW', () {
      final out = bakeExifOnDecoded(twoByOne(), 6);
      expect(out.width, 1);
      expect(out.height, 2);
      expect(rgbaAt(out, 0, 0), red);
      expect(rgbaAt(out, 0, 1), blue);
    });

    test('orientation 7: transverse (rotate 270 + flip horizontal)', () {
      final out = bakeExifOnDecoded(twoByOne(), 7);
      expect(out.width, 1);
      expect(out.height, 2);
      expect(rgbaAt(out, 0, 0), blue);
      expect(rgbaAt(out, 0, 1), red);
    });

    test('orientation 8: rotate 270 CW', () {
      final out = bakeExifOnDecoded(twoByOne(), 8);
      expect(out.width, 1);
      expect(out.height, 2);
      expect(rgbaAt(out, 0, 0), blue);
      expect(rgbaAt(out, 0, 1), red);
    });
  });

  group('A7 offset-view export regression', () {
    test('TC-214 an offset-view RGBA buffer exports the same pixels', () async {
      const width = 4;
      const height = 4;
      final pixels = Uint8List(width * height * 4);
      for (var i = 0; i < pixels.length; i += 4) {
        pixels[i] = 200; // R
        pixels[i + 1] = 40; // G
        pixels[i + 2] = 10; // B
        pixels[i + 3] = 255; // A
      }
      // The FFI decoder can hand back a VIEW into a larger buffer. Build one
      // with a non-zero offsetInBytes holding the identical pixels.
      final backing = Uint8List(64 + pixels.length)
        ..setRange(64, 64 + pixels.length, pixels);
      final view = Uint8List.view(backing.buffer, 64, pixels.length);
      expect(view.offsetInBytes, 64);

      final flat = await exportJpegForTest(
        DecodedRgba(rgba: pixels, width: width, height: height),
      );
      final offset = await exportJpegForTest(
        DecodedRgba(rgba: view, width: width, height: height),
      );

      expect(offset, isNotNull);
      expect(offset, equals(flat));
    });

    test('TC-215 a length/dimension mismatch returns null, not garbage', () async {
      final short = Uint8List(4 * 4 * 4 - 8);
      final result = await exportJpegForTest(
        DecodedRgba(rgba: short, width: 4, height: 4),
      );
      expect(result, isNull);
    });
  });

  group('shared orientation table parity', () {
    test('TC-216 bakeExifOnDecoded agrees with the shared table for 1..8',
        () async {
      // A 2x1 image: left pixel red, right pixel blue. Any rotation or mirror
      // moves those two pixels somewhere predictable.
      img.Image source() {
        final im = img.Image(width: 2, height: 1, numChannels: 4);
        im.setPixelRgba(0, 0, 255, 0, 0, 255);
        im.setPixelRgba(1, 0, 0, 0, 255, 255);
        return im;
      }

      for (var orientation = 1; orientation <= 8; orientation++) {
        final t = exifTransformFor(orientation);
        final baked = bakeExifOnDecoded(source(), orientation);
        final expectedWidth = t.quarterTurnsCw.isOdd ? 1 : 2;
        final expectedHeight = t.quarterTurnsCw.isOdd ? 2 : 1;
        expect(baked.width, expectedWidth, reason: 'orientation $orientation');
        expect(baked.height, expectedHeight, reason: 'orientation $orientation');
      }
    });
  });

  test('TC-312: exporting a TIFF produces a JPEG with long edge <= 2048 and '
      'Orientation == 1', () async {
    final tmp = Directory.systemTemp.createTempSync('halcyon_tiff_export');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // A real TIFF file must exist at this path: exportBytesFor calls
    // dartImageLoad, whose bitmap branch reads the IFD0 extent and
    // orientation from the file before returning NeedsRawDecode, and
    // _attachSourceExif re-reads the same file with package:exif.
    final path = '${tmp.path}${Platform.pathSeparator}scan.tif';
    File(path).writeAsBytesSync(
      img.encodeTiff(img.Image(width: 60, height: 40)),
    );

    // 3000x2000 forces the resize; the fake decoder stands in for the
    // dispatching decoder so the test never loads a real dylib.
    final rgba = Uint8List(3000 * 2000 * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255; // opaque
    }
    final jpeg = await PhotoExportService.exportBytesFor(
      path,
      decoder: (p) async =>
          DecodedRgba(rgba: rgba, width: 3000, height: 2000),
    );

    expect(jpeg, isNotNull);
    final out = img.decodeJpg(jpeg!)!;
    expect(out.width, lessThanOrEqualTo(2048));
    expect(out.height, lessThanOrEqualTo(2048));
    expect(out.width == 2048 || out.height == 2048, isTrue,
        reason: 'the long edge is capped AT 2048, not below it');
    // Orientation must be read from the exported bytes via an INDEPENDENT
    // oracle (pkg:exif), NOT `out.exif.imageIfd['Orientation']`: `img.decodeJpg`
    // unconditionally clears the Orientation tag on every decode because it
    // bakes orientation into pixel layout (documented in the P-14 carry-over
    // test above), so the tag can never be observed through the decoded image.
    final outputTags = await pkg_exif.readExifFromBytes(jpeg);
    expect(outputTags['Image Orientation']?.values.firstAsInt(), 1,
        reason: 'pixels are already rotated; the tag must not double-apply');
  });
}
