import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_normalizer.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

Uint8List _bytes(int length, {int fill = 7}) =>
    Uint8List.fromList(List<int>.filled(length, fill));

({Uint8List rgba, int width, int height}) _rgba(int w, int h) =>
    (rgba: Uint8List(w * h * 4), width: w, height: h);

void main() {
  setUp(() {
    resetNormalizeCounters();
    resetReencodeCounters();
  });

  // TC-413
  test('input at or under the passthrough size is returned untouched',
      () async {
    final input = _bytes(kNormalizePassthroughMaxBytes);
    var decodes = 0;
    final out = await normalizeEncodedPayload(
      encoded: input,
      encoder: (rgba, {required width, required height, required quality}) async =>
          _bytes(10),
      decodeToRgba: (bytes) async {
        decodes++;
        return _rgba(4, 4);
      },
    );
    expect(out, isA<EncodedPayload>());
    expect(identical((out as EncodedPayload).bytes, input), isTrue);
    expect(decodes, 0);
    expect(normalizeFallbacks, 0);
    expect(reencodeFallbacks, 0);
  });

  // TC-414
  test('large input is decoded and re-encoded at quality 70', () async {
    final input = _bytes(kNormalizePassthroughMaxBytes + 1);
    final calls = <({int width, int height, int quality})>[];
    final out = await normalizeEncodedPayload(
      encoded: input,
      encoder: (rgba, {required width, required height, required quality}) async {
        calls.add((width: width, height: height, quality: quality));
        return _bytes(64, fill: 3);
      },
      decodeToRgba: (bytes) async => _rgba(80, 60),
    );
    expect(calls, <({int width, int height, int quality})>[
      (width: 80, height: 60, quality: 70),
    ]);
    expect((out as EncodedPayload).bytes.length, 64);
    expect(normalizeFallbacks, 0);
    expect(reencodeFallbacks, 0);
  });

  // TC-415 (amendment E-M1: delegates to reencodePayload, shared counter)
  test('undecodable input keeps the original bytes and counts a fallback',
      () async {
    final input = _bytes(kNormalizePassthroughMaxBytes + 1);
    var encoderCalls = 0;
    final out = await normalizeEncodedPayload(
      encoded: input,
      encoder: (rgba, {required width, required height, required quality}) async {
        encoderCalls++;
        return _bytes(4);
      },
      decodeToRgba: (bytes) async => null,
    );
    expect(identical((out as EncodedPayload).bytes, input), isTrue);
    expect(encoderCalls, 0);
    expect(reencodeFallbacks, 1);
    expect(normalizeFallbacks, 0);
  });

  // TC-416 (amendment E-M1: delegates to reencodePayload, shared counter)
  test('a throwing encoder keeps the original bytes', () async {
    final input = _bytes(kNormalizePassthroughMaxBytes + 1);
    final out = await normalizeEncodedPayload(
      encoded: input,
      encoder: (rgba, {required width, required height, required quality}) async {
        throw StateError('boom');
      },
      decodeToRgba: (bytes) async => _rgba(80, 60),
    );
    expect(identical((out as EncodedPayload).bytes, input), isTrue);
    expect(reencodeFallbacks, 1);
    expect(normalizeFallbacks, 0);
  });

  // TC-417 (normalisation-specific refusal, its own counter)
  test('an encoder output larger than the input is discarded', () async {
    final input = _bytes(kNormalizePassthroughMaxBytes + 1);
    final out = await normalizeEncodedPayload(
      encoded: input,
      encoder: (rgba, {required width, required height, required quality}) async =>
          _bytes(input.length + 1),
      decodeToRgba: (bytes) async => _rgba(80, 60),
    );
    expect(identical((out as EncodedPayload).bytes, input), isTrue);
    expect(normalizeFallbacks, 1);
    expect(reencodeFallbacks, 0);
  });

  // TC-418 (amendment E-M1: delegates to reencodePayload, shared counter)
  test('an rgba buffer disagreeing with its dimensions never reaches the '
      'encoder', () async {
    final input = _bytes(kNormalizePassthroughMaxBytes + 1);
    var encoderCalls = 0;
    final out = await normalizeEncodedPayload(
      encoded: input,
      encoder: (rgba, {required width, required height, required quality}) async {
        encoderCalls++;
        return _bytes(4);
      },
      decodeToRgba: (bytes) async => (rgba: Uint8List(8), width: 80, height: 60),
    );
    expect(identical((out as EncodedPayload).bytes, input), isTrue);
    expect(encoderCalls, 0);
    expect(reencodeFallbacks, 1);
    expect(normalizeFallbacks, 0);
  });

  // TC-419 (amendment E-M3: gate is an explicit parameter, own instance)
  test('the gate bounds how many normalisations decode at once', () async {
    final gate = NormalizeGate(width: 2);
    var live = 0;
    var maxLive = 0;
    final completers = <Completer<void>>[];
    final futures = <Future<SourcePayload>>[];
    for (var i = 0; i < 5; i++) {
      final completer = Completer<void>();
      completers.add(completer);
      futures.add(
        normalizeEncodedPayload(
          encoded: _bytes(kNormalizePassthroughMaxBytes + 1),
          encoder:
              (rgba, {required width, required height, required quality}) async =>
                  _bytes(4),
          decodeToRgba: (bytes) async {
            live++;
            maxLive = live > maxLive ? live : maxLive;
            await completer.future;
            live--;
            return _rgba(4, 4);
          },
          gate: gate,
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(maxLive, 2);
    for (final c in completers) {
      c.complete();
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(futures);
    expect(maxLive, 2);
  });
}
