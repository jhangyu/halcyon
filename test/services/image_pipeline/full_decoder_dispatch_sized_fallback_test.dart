import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/full_decoder_dispatch.dart';

DecodedRgba _fixture() =>
    DecodedRgba(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2);

void main() {
  setUp(debugResetSizedDecodeLatch);
  tearDown(debugResetSizedDecodeLatch);

  test(
    'TC-371 a throwing sized arm falls back to the full decode and latches, '
    'so later files skip the sized arm entirely',
    () async {
      var sizedCalls = 0;
      var fullCalls = 0;
      Future<DecodedRgba> sized(String p, {required int maxDim}) async {
        sizedCalls++;
        throw StateError('sized symbol misbehaved');
      }

      Future<DecodedRgba> full(String p) async {
        fullCalls++;
        return _fixture();
      }

      for (var i = 0; i < 5; i++) {
        final out = await dispatchSizedDecode(
          '/tmp/f$i.dng',
          maxDim: 200,
          rawArm: sized,
          fullDecodeFallback: full,
        );
        expect(out.width, 2);
      }

      expect(sizedCalls, 1, reason: 'the latch must stop re-asking');
      expect(fullCalls, 5);
      expect(debugSizedDecodeLatched, isTrue);
    },
  );

  test(
    'TC-372 sized AND full both throwing is a per-file failure: the error '
    'propagates and the latch stays clear',
    () async {
      var sizedCalls = 0;
      Future<DecodedRgba> sized(String p, {required int maxDim}) async {
        sizedCalls++;
        throw StateError('sized failed');
      }

      Future<DecodedRgba> full(String p) async {
        throw StateError('this file is corrupt');
      }

      await expectLater(
        dispatchSizedDecode(
          '/tmp/bad.dng',
          maxDim: 200,
          rawArm: sized,
          fullDecodeFallback: full,
        ),
        throwsA(isA<StateError>()),
      );
      expect(debugSizedDecodeLatched, isFalse);

      // The next file must still get a real sized attempt.
      await expectLater(
        dispatchSizedDecode(
          '/tmp/bad2.dng',
          maxDim: 200,
          rawArm: sized,
          fullDecodeFallback: full,
        ),
        throwsA(isA<StateError>()),
      );
      expect(sizedCalls, 2);
    },
  );

  test(
    'TC-372b designed refusals propagate unchanged, never latch and never '
    'trigger a fallback',
    () async {
      var fullCalls = 0;
      Future<DecodedRgba> full(String p) async {
        fullCalls++;
        return _fixture();
      }

      Future<DecodedRgba> tooLarge(String p, {required int maxDim}) async {
        throw const ImageTooLargeException('IMAGE_TOO_LARGE: 30000x30000');
      }

      await expectLater(
        dispatchSizedDecode(
          '/tmp/huge.tif',
          maxDim: 200,
          tiffArm: tooLarge,
          fullDecodeFallback: full,
        ),
        throwsA(isA<ImageTooLargeException>()),
      );

      await expectLater(
        dispatchSizedDecode(
          '/tmp/nothing.txt',
          maxDim: 200,
          fullDecodeFallback: full,
        ),
        throwsA(isA<UnsupportedError>()),
      );

      expect(fullCalls, 0);
      expect(debugSizedDecodeLatched, isFalse);
    },
  );
}
