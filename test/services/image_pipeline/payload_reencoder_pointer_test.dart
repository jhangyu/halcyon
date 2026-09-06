// R2-WP3b (gc-remediation, 2026-09-06): pointer-based encode dispatch on
// `reencodePayload`. Deliberately a SEPARATE file from `encode_test.dart`
// (which already has an in-flight WP4/WP5 edit this round) so this task's
// additions never touch a file another concurrent worker owns/is editing.
//
// Erratum E-WP3b: the plan's original design of widening `PayloadEncoder`
// itself with optional `nativeAddress`/`keepAlive` params was rejected --
// Dart function-type subtyping requires every existing closure to declare
// every named parameter the target type has, optional or not, so widening
// the shared typedef would have broken all ~24 existing
// `(rgba, {required width, required height, required quality})` test
// closures across the suite. Approved fix (team-lead ruling): a wholly
// separate `PointerPayloadEncoder` typedef, passed as an additional OPTIONAL
// parameter to `reencodePayload`, defaulting to null/0 so every existing
// caller and closure is untouched.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

void main() {
  group('payload_reencoder_pointer_test.dart (WP3b)', () {
    PixelPayload pixelsRe(int w, int h) =>
        PixelPayload(rgba: Uint8List(w * h * 4), width: w, height: h);

    setUp(resetReencodeCounters);

    // TC-1079
    test('native-backed frames take the pointer entry', () async {
      int? seenAddress;
      var copyEncoderCalls = 0;
      final result = await reencodePayload(
        encoder: (rgba, {required width, required height, required quality}) async {
          copyEncoderCalls++;
          return Uint8List(width * height);
        },
        pointerEncoder: ({
          required nativeAddress,
          required width,
          required height,
          required quality,
          keepAlive,
        }) async {
          seenAddress = nativeAddress;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        nativeAddress: 0xDEAD,
        fallback: () async => pixelsRe(10, 10),
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      expect(result, isA<EncodedPayload>());
      expect(seenAddress, 0xDEAD);
      expect(copyEncoderCalls, 0, reason: 'the copy encoder must not run when the pointer path is taken');
      expect(reencodeFallbacks, 0);
    });

    // TC-1080
    test('Dart-heap frames (nativeAddress == 0) take the copy entry', () async {
      var pointerEncoderCalls = 0;
      var copyEncoderCalls = 0;
      final result = await reencodePayload(
        encoder: (rgba, {required width, required height, required quality}) async {
          copyEncoderCalls++;
          return Uint8List(width * height);
        },
        pointerEncoder: ({
          required nativeAddress,
          required width,
          required height,
          required quality,
          keepAlive,
        }) async {
          pointerEncoderCalls++;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        nativeAddress: 0, // rotated path / legacy arm: no native buffer
        fallback: () async => pixelsRe(10, 10),
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      expect(result, isA<EncodedPayload>());
      expect(pointerEncoderCalls, 0);
      expect(copyEncoderCalls, 1);
      expect(reencodeFallbacks, 0);
    });

    // TC-1081
    test('no pointerEncoder supplied takes the copy entry (default null)', () async {
      var copyEncoderCalls = 0;
      final result = await reencodePayload(
        encoder: (rgba, {required width, required height, required quality}) async {
          copyEncoderCalls++;
          return Uint8List(width * height);
        },
        nativeAddress: 0xDEAD, // even a non-zero address must not dispatch
        fallback: () async => pixelsRe(10, 10),
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      expect(result, isA<EncodedPayload>());
      expect(copyEncoderCalls, 1);
    });

    // TC-1082
    test('pointer-path native-unavailable failure still degrades to the pixel fallback', () async {
      final fallback = pixelsRe(10, 10);
      final result = await reencodePayload(
        encoder: (rgba, {required width, required height, required quality}) async =>
            Uint8List(width * height),
        pointerEncoder: ({
          required nativeAddress,
          required width,
          required height,
          required quality,
          keepAlive,
        }) async =>
            throw StateError('CeyxEncodeUnavailableException (simulated: no native symbols)'),
        nativeAddress: 0xDEAD,
        fallback: () async => fallback,
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      expect(identical(result, fallback), isTrue);
      expect(reencodeFallbacks, 1);
    });

    // TC-1048
    test('keepAlive is forwarded to the pointer encoder unchanged', () async {
      final handle = Object();
      Object? seenKeepAlive;
      await reencodePayload(
        encoder: (rgba, {required width, required height, required quality}) async =>
            Uint8List(width * height),
        pointerEncoder: ({
          required nativeAddress,
          required width,
          required height,
          required quality,
          keepAlive,
        }) async {
          seenKeepAlive = keepAlive;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        nativeAddress: 0xDEAD,
        keepAlive: handle,
        fallback: () async => pixelsRe(10, 10),
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      expect(identical(seenKeepAlive, handle), isTrue);
    });
  });
}
