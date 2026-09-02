import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_normalizer.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

Future<T> withStubDecoder<T>(
  EncodedRgbaDecoder stub,
  Future<T> Function() body,
) async {
  final previous = debugEncodedRgbaDecoderOverride;
  debugEncodedRgbaDecoderOverride = stub;
  try {
    return await body();
  } finally {
    debugEncodedRgbaDecoderOverride = previous;
  }
}

Future<NativeImageResult> _needsRawDecode(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

Future<DecodedRgba> _fakeDecoder(String path) async =>
    DecodedRgba(rgba: Uint8List(64 * 48 * 4), width: 64, height: 48);

Future<Uint8List> _fakeEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, width & 0xFF, height & 0xFF]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-364
  test('load() re-encodes a decoded RAW into a plain EncodedPayload', () async {
    const source = PhotoSource(
      loader: _needsRawDecode,
      dngDecoder: _fakeDecoder,
      payloadEncoder: _fakeEncoder,
    );
    final outcome = await source.load('x.dng', longEdge: 32);
    expect(outcome.payload, isA<EncodedPayload>());
    expect((outcome.payload! as EncodedPayload).bytes.first, 0xFF);
    // The piggyback RGBA must SURVIVE the re-encode: it is a free tier-2 upload.
    expect(outcome.fullRes, isNotNull);
  });

  // TC-364b — the two decode paths must not diverge
  test('loadExpensive() re-encodes identically', () async {
    const source = PhotoSource(
      loader: _needsRawDecode,
      dngDecoder: _fakeDecoder,
      payloadEncoder: _fakeEncoder,
    );
    final outcome =
        await source.loadExpensive('x.dng', longEdge: 32, exifOrientation: 1);
    expect(outcome.payload, isA<EncodedPayload>());
  });

  // TC-365
  test('no encoder configured -> unchanged PixelPayload behaviour', () async {
    const source = PhotoSource(loader: _needsRawDecode, dngDecoder: _fakeDecoder);
    final outcome = await source.load('x.dng', longEdge: 32);
    expect(outcome.payload, isA<PixelPayload>());
  });

  // TC-420
  test('a JPG payload is the encoder q70 output, not the file bytes', () async {
    resetNormalizeCounters();
    final fileBytes = Uint8List.fromList(
      List<int>.filled(kNormalizePassthroughMaxBytes + 1, 9),
    );
    final calls = <({int width, int height, int quality})>[];
    final source = PhotoSource(
      loader: (path, {required purpose, int? targetLongEdge}) async => NativeImageBytes(fileBytes),
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async {
        calls.add((width: width, height: height, quality: quality));
        return Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF]);
      },
    );

    final outcome = await withStubDecoder(
      (bytes) async => (rgba: Uint8List(40 * 30 * 4), width: 40, height: 30),
      () => source.load('/x/a.jpg', longEdge: 2800),
    );

    expect(calls, <({int width, int height, int quality})>[
      (width: 40, height: 30, quality: 70),
    ]);
    expect((outcome.payload! as EncodedPayload).bytes.length, 3);
    expect(outcome.observedCost, SourceCost.cheap);
    expect(outcome.fullRes, isNull);
  });

  // TC-421
  test('payloadEncoder null keeps the loader bytes identical', () async {
    final fileBytes = Uint8List.fromList(
      List<int>.filled(kNormalizePassthroughMaxBytes + 1, 9),
    );
    var decodes = 0;
    final source = PhotoSource(
      loader: (path, {required purpose, int? targetLongEdge}) async => NativeImageBytes(fileBytes),
    );
    final outcome = await withStubDecoder(
      (bytes) async {
        decodes++;
        return (rgba: Uint8List(4), width: 1, height: 1);
      },
      () => source.load('/x/a.jpg', longEdge: 2800),
    );
    expect(
      identical((outcome.payload! as EncodedPayload).bytes, fileBytes),
      isTrue,
    );
    expect(decodes, 0);
  });

  // TC-422
  test('bytes recovered after a native failure go through the normaliser',
      () async {
    // The recovery arm reads a real file through the pure-Dart walker, so this
    // asserts the WIRING: an unreadable path yields a null payload and, since
    // the normaliser was never reached, no fallback is counted. If the arm
    // were wired to normalise BEFORE the null check, the counter would move.
    resetNormalizeCounters();
    final source = PhotoSource(
      loader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageFailure('X', 'no bridge'),
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async =>
              Uint8List.fromList(<int>[1]),
    );
    final outcome = await source.load('/x/missing.arw', longEdge: 2800);
    expect(outcome.payload, isNull);
    expect(normalizeFallbacks, 0);
  });

  // TC-423
  test('the discovery pass never normalises', () async {
    resetNormalizeCounters();
    var decodes = 0;
    final source = PhotoSource(
      loader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async =>
          DecodedRgba(rgba: Uint8List(4), width: 1, height: 1),
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async =>
              Uint8List.fromList(<int>[1]),
    );
    final outcome = await withStubDecoder(
      (bytes) async {
        decodes++;
        return (rgba: Uint8List(4), width: 1, height: 1);
      },
      () => source.load('/x/a.arw', longEdge: 2800, allowExpensive: false),
    );
    expect(outcome.deferred, isTrue);
    expect(outcome.payload, isNull);
    expect(decodes, 0);
  });
}
