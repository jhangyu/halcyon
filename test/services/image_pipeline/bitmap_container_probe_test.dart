import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/image_pipeline/bitmap_container_probe.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/synthetic_dng.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('halcyon_bitmap_probe');
  });
  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> write(String name, Uint8List bytes) async {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  group('TC-330: the probe seam routes by container family', () {
    test('a .tif is read by the IFD0 walker, not the HEIF probe', () async {
      var heifCalls = 0;
      Future<BitmapContainerExtent?> neverHeif(String path) async {
        heifCalls++;
        return null;
      }

      final path = await write(
        'scan.tif',
        buildSyntheticTiffHeader(width: 800, height: 600, orientation: 6),
      );
      final extent = await probeBitmapContainer(path, heifProbe: neverHeif);
      expect(extent, isNotNull);
      expect(extent!.width, 800);
      expect(extent.height, 600);
      expect(extent.orientation, 6);
      expect(
        heifCalls,
        0,
        reason: 'a TIFF must never reach the native HEIF probe — that would '
            'load a dylib on a path that has a pure-Dart answer',
      );
    });

    test('a .heic is read by the HEIF probe, not the IFD0 walker', () async {
      var heifCalls = 0;
      Future<BitmapContainerExtent?> fakeHeif(String path) async {
        heifCalls++;
        return (width: 4032, height: 3024, orientation: 1);
      }

      // Content is irrelevant: the IFD0 walker would return null on ISO-BMFF
      // anyway, so a non-null answer can only have come from the HEIF arm.
      final path = await write('shot.heic', Uint8List.fromList([0, 0, 0, 24]));
      final extent = await probeBitmapContainer(path, heifProbe: fakeHeif);
      expect(heifCalls, 1);
      expect(extent, isNotNull);
      expect(extent!.width, 4032);
      expect(extent.height, 3024);
      expect(extent.orientation, 1);
    });

    test('an unavailable HEIF probe yields null, never a throw', () async {
      Future<BitmapContainerExtent?> unavailable(String path) async => null;
      final path = await write('shot2.heic', Uint8List.fromList([0, 0, 0, 24]));
      expect(await probeBitmapContainer(path, heifProbe: unavailable), isNull);
    });

    test('a throwing HEIF probe is swallowed into null', () async {
      Future<BitmapContainerExtent?> boom(String path) async =>
          throw StateError('dylib exploded');
      final path = await write('shot3.heic', Uint8List.fromList([0, 0, 0, 24]));
      // The loader is documented as never throwing, so the seam beneath it
      // must absorb everything.
      expect(await probeBitmapContainer(path, heifProbe: boom), isNull);
    });

    test('bitmapContainerOrientation falls back to 1 when nothing answers',
        () async {
      Future<BitmapContainerExtent?> unavailable(String path) async => null;
      final path = await write('shot4.heic', Uint8List.fromList([0, 0, 0, 24]));
      expect(
        await bitmapContainerOrientation(path, heifProbe: unavailable),
        kDefaultExifOrientation,
      );
    });
  });
}
