import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import '../../support/temp_dirs.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/synthetic_dng.dart';

DecodedRgba _tinyDecoded() {
  final rgba = Uint8List(2 * 2 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 255; // opaque
  }
  return DecodedRgba(rgba: rgba, width: 2, height: 2);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('halcyon_wiring');
  });
  tearDownAll(() => deleteTempDir(tmp));

  Future<File> writeContainer(String name) async {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(
      buildSyntheticTiffHeader(width: 800, height: 600, orientation: 1),
      flush: true,
    );
    return file;
  }

  /// Drives one sidebar thumbnail sweep over a single item and records which
  /// paths the sized decoder was asked for. Uses the real controller API
  /// (`preloadThumbnails` with `startIdx`/`endIdx`); the sweep runs behind a
  /// 100ms debounce timer, so it awaits past that before reading the calls.
  Future<List<String>> sizedDecoderCallsFor(String name) async {
    final file = await writeContainer(name);
    final calls = <String>[];
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate'),
      sidebarRawDecoder: (path, {required int maxDim}) async {
        calls.add(path);
        expect(maxDim, 200);
        return _tinyDecoded();
      },
    );
    addTearDown(controller.dispose);
    final items = [PhotoItem(id: 'a', files: [file])];
    await controller.preloadThumbnails(
      items: items,
      startIdx: 0,
      endIdx: 0,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return calls;
  }

  test('a .tif reaches the sidebar sized decoder', () async {
    expect(await sizedDecoderCallsFor('a.tif'), hasLength(1));
  });

  test('a D2 browse-only .cr2 does NOT reach the sidebar sized decoder',
      () async {
    expect(await sizedDecoderCallsFor('a.cr2'), isEmpty);
  });

  test('a .webp does NOT reach the sidebar sized decoder', () async {
    expect(await sizedDecoderCallsFor('a.webp'), isEmpty);
  });
}
