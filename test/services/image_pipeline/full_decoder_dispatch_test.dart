import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import '../../support/temp_dirs.dart';
import 'package:image/image.dart' as img;

import 'package:ceyx/ceyx.dart';

import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/full_decoder_dispatch.dart';
import 'package:halcyon_flutter/services/image_pipeline/heif_decode_service.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

import '../../support/synthetic_dng.dart';

/// A 4x2 RGBA buffer whose first pixel is a distinct marker, so a test cannot
/// pass by receiving "some" DecodedRgba.
DecodedRgba _fakeDecoded({int width = 4, int height = 2}) {
  final rgba = Uint8List(width * height * 4);
  rgba[0] = 0xA5;
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('halcyon_dispatch');
  });
  tearDownAll(() => deleteTempDir(tmp));

  Future<String> write(String name, Uint8List bytes) async {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// A real, decodable 4x2 TIFF with a distinguishable pixel pattern.
  Uint8List realTiff({int width = 4, int height = 2}) {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(x, y, (x * 30) & 0xFF, (y * 60) & 0xFF, 7);
      }
    }
    return img.encodeTiff(image);
  }

  group('dispatchFullDecode', () {
    test('TC-309: routes .tif and .tiff to the TIFF arm', () async {
      final calls = <String>[];
      Future<DecodedRgba> tiffArm(String path) async {
        calls.add(path);
        return _fakeDecoded();
      }

      Future<DecodedRgba> rawArm(String path) async =>
          fail('the RAW arm must not be called for a TIFF');

      for (final name in ['a.tif', 'b.TIFF']) {
        final decoded = await dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}$name',
          rawArm: rawArm,
          tiffArm: tiffArm,
        );
        expect(decoded.rgba[0], 0xA5);
      }
      expect(calls, hasLength(2));
    });

    test('TC-309: routes .dng and .arw to the engine arm', () async {
      final calls = <String>[];
      Future<DecodedRgba> rawArm(String path) async {
        calls.add(path);
        return _fakeDecoded();
      }

      Future<DecodedRgba> tiffArm(String path) async =>
          fail('the TIFF arm must not be called for a RAW container');

      for (final name in ['a.dng', 'b.arw']) {
        await dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}$name',
          rawArm: rawArm,
          tiffArm: tiffArm,
        );
      }
      expect(calls, hasLength(2));
    });

    test('TC-309: throws UnsupportedError for an unroutable extension',
        () async {
      Future<DecodedRgba> never(String path) async => fail('must not run');
      for (final name in ['a.xyz', 'b.jpg', 'c.webp', 'd.cr2']) {
        await expectLater(
          dispatchFullDecode(
            '${tmp.path}${Platform.pathSeparator}$name',
            rawArm: never,
            tiffArm: never,
          ),
          throwsUnsupportedError,
          reason: '$name has no full-decode route',
        );
      }
    });
  });

  group('dispatchSizedDecode', () {
    test('TC-309: routes .tif to the TIFF arm and .dng to the engine arm',
        () async {
      var tiffCalls = 0;
      var rawCalls = 0;
      Future<DecodedRgba> tiffArm(String path, {required int maxDim}) async {
        expect(maxDim, 200);
        tiffCalls++;
        return _fakeDecoded();
      }

      Future<DecodedRgba> rawArm(String path, {required int maxDim}) async {
        rawCalls++;
        return _fakeDecoded();
      }

      await dispatchSizedDecode(
        '${tmp.path}${Platform.pathSeparator}a.tif',
        maxDim: 200,
        rawArm: rawArm,
        tiffArm: tiffArm,
      );
      await dispatchSizedDecode(
        '${tmp.path}${Platform.pathSeparator}a.dng',
        maxDim: 200,
        rawArm: rawArm,
        tiffArm: tiffArm,
      );
      expect(tiffCalls, 1);
      expect(rawCalls, 1);
    });
  });

  group('TIFF arm', () {
    test('decodes a real TIFF to a self-consistent RGBA buffer', () async {
      final path = await write('good.tif', realTiff());
      final decoded = await decodeTiffFull(path);
      expect(decoded.width, 4);
      expect(decoded.height, 2);
      expect(decoded.rgba.length, 4 * 2 * 4);
    });

    test('honours maxDim as a downscale request', () async {
      final path = await write('big.tif', realTiff(width: 400, height: 200));
      final decoded = await decodeTiffSized(path, maxDim: 100);
      expect(decoded.width, 100);
      expect(decoded.height, 50);
      expect(decoded.rgba.length, 100 * 50 * 4);
    });

    test('throws on a TIFF package:image cannot decode', () async {
      // buildSyntheticTiffHeader carries no pixel data. The plan assumed
      // `img.decodeTiff` returns null on this input (-> StateError), but
      // package:image ^4.9.2 instead THROWS a TypeError from `_decodeTile`
      // (no StripOffsets). The plan already treats a decodeTiff throw as an
      // unchanged rethrow / permanent miss, so this widens only the assertion
      // to match on-disk reality: an undecodable TIFF makes the full arm
      // throw (StateError from the null path OR the library's own Error).
      final path = await write(
        'corrupt.tif',
        buildSyntheticTiffHeader(width: 800, height: 600),
      );
      await expectLater(decodeTiffFull(path), throwsA(isA<Error>()));
    });

    test('TC-308: the sized arm refuses an over-budget extent BEFORE any '
        'decode is attempted', () async {
      var decodeAttempts = 0;
      Future<DecodedRgba> spy(Uint8List bytes, {int? maxDim}) async {
        decodeAttempts++;
        return _fakeDecoded();
      }

      final path = await write(
        'huge_sidebar.tif',
        buildSyntheticTiffHeader(width: 30000, height: 30000),
      );
      await expectLater(
        decodeTiffSized(path, maxDim: 200, decodeBytes: spy),
        throwsA(
          isA<ImageTooLargeException>().having(
            (e) => e.message,
            'message',
            contains('IMAGE_TOO_LARGE'),
          ),
        ),
      );
      expect(
        decodeAttempts,
        0,
        reason: 'the ceiling must be checked before the decode, not after — '
            'the sidebar path never reaches the loader\'s budget check',
      );
    });

    test('TC-308: an in-budget TIFF still reaches the decoder on the sized '
        'path', () async {
      var decodeAttempts = 0;
      Future<DecodedRgba> spy(Uint8List bytes, {int? maxDim}) async {
        decodeAttempts++;
        return _fakeDecoded();
      }

      final path = await write('small_sidebar.tif', realTiff());
      await decodeTiffSized(path, maxDim: 200, decodeBytes: spy);
      expect(decodeAttempts, 1);
    });
  });

  group('phase-2 HEIC arm', () {
    test('TC-309: routes .heic/.heif to the HEIF arm, never to TIFF or RAW',
        () async {
      final calls = <String>[];
      Future<DecodedRgba> heifArm(String path) async {
        calls.add(path);
        return _fakeDecoded();
      }

      Future<DecodedRgba> never(String path) async =>
          fail('only the HEIF arm may run for a HEIC container');

      for (final name in ['a.heic', 'b.HEIF']) {
        final decoded = await dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}$name',
          rawArm: never,
          tiffArm: never,
          heifArm: heifArm,
        );
        expect(decoded.rgba[0], 0xA5);
      }
      expect(calls, hasLength(2));
    });

    test('TC-309: the sized path routes .heic to the HEIF arm with maxDim',
        () async {
      var heifCalls = 0;
      Future<DecodedRgba> heifArm(String path, {required int maxDim}) async {
        expect(maxDim, 200);
        heifCalls++;
        return _fakeDecoded();
      }

      Future<DecodedRgba> never(String path, {required int maxDim}) async =>
          fail('only the HEIF arm may run for a HEIC container');

      await dispatchSizedDecode(
        '${tmp.path}${Platform.pathSeparator}a.heic',
        maxDim: 200,
        rawArm: never,
        tiffArm: never,
        heifArm: heifArm,
      );
      expect(heifCalls, 1);
    });

    test('TC-327: an unavailable HEIF library becomes a decoder throw, not a '
        'crash and not the D3 no-decoder state', () async {
      // What the ceyx service does on a build with -DDNG_ENABLE_HEIF=OFF.
      Future<DecodedRgba> unavailable(String path) async =>
          throw HeifUnavailableException(path);

      await expectLater(
        dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}gone.heic',
          heifArm: unavailable,
        ),
        throwsA(isA<HeifUnavailableException>()),
      );
    });

    test('TC-327: PhotoSource turns that throw into the uniform permanent '
        'miss, with failureCode null', () async {
      final source = PhotoSource(
        loader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => throw HeifUnavailableException(path),
      );
      final outcome = await source.load('/tmp/gone.heic', longEdge: 2800);
      expect(outcome.payload, isNull);
      expect(outcome.deferred, isFalse);
      expect(
        outcome.failureCode,
        isNull,
        reason: 'NO_NATIVE_DECODER (D3) stays reserved for dngDecoder == null; '
            'a HEIC on a HEIF-less build is an ordinary permanent miss, and '
            'the app must not report "decoding unavailable" app-wide',
      );
      expect(outcome.observedCost, SourceCost.expensive);
    });

    test('TC-328: a length/geometry mismatch is rejected before it can reach '
        'decodeImageFromPixels', () async {
      // The adapter's own check. A buffer that disagrees with its declared
      // geometry would otherwise blow _imageFromPixels' assert deep inside the
      // provider, where the message names neither the file nor the decoder.
      await expectLater(
        heifImageToDecodedRgba(
          rgba: Uint8List(4 * 2 * 4 - 1),
          width: 4,
          height: 2,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('31'), contains('32')),
          ),
        ),
      );
    });

    test('TC-328: a consistent buffer passes through unchanged', () async {
      final rgba = Uint8List(4 * 2 * 4);
      rgba[0] = 0xA5;
      final decoded =
          await heifImageToDecodedRgba(rgba: rgba, width: 4, height: 2);
      expect(decoded.width, 4);
      expect(decoded.height, 2);
      expect(decoded.rgba[0], 0xA5);
    });
  });
}
