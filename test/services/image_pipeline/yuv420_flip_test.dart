import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/frame_bytes.dart';

/// mem8 T15a (SR-12) — the yuv420 flip's Halcyon-side seam, default and
/// constant split.
void main() {
  final pool = CeyxNativeBufferPool.shared;

  tearDown(debugResetUpconvertSeam);

  /// A spy converter that writes a recognisable pattern into the destination,
  /// so "did the caller get the CONVERTED bytes or the source bytes?" is
  /// decidable from the returned buffer alone.
  ///
  /// It is an injection point for T13's native entry, never an alternative
  /// implementation: Dart must not open-code the colour maths (SR-11).
  final calls = <({int srcCapacity, int dstCapacity, int width, int height})>[];
  void spyConverter({
    required int srcAddress,
    required int srcCapacity,
    required int dstAddress,
    required int dstCapacity,
    required int width,
    required int height,
  }) {
    calls.add((
      srcCapacity: srcCapacity,
      dstCapacity: dstCapacity,
      width: width,
      height: height,
    ));
    ffi.Pointer<ffi.Uint8>.fromAddress(
      dstAddress,
    ).asTypedList(dstCapacity).fillRange(0, dstCapacity, 0xFF);
  }

  DecodedRgba yuvFrame(int w, int h, {void Function()? releaseNative}) {
    final bytes = ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h);
    return DecodedRgba(
      rgba: Uint8List(bytes),
      width: w,
      height: h,
      format: CeyxOutputFormat.yuv420,
      releaseNative: releaseNative,
    );
  }

  setUp(calls.clear);

  group('TC-1330..1334: the seam', () {
    test(
      'TC-1330: neither short-circuit returns unconverted bytes — the seam is '
      'at the conversion points, not at _imageFromPixels alone',
      () async {
        // BOTH identity short-circuits bypass `_imageFromPixels` entirely and
        // hand `decoded.rgba` back (one as an owned copy, one verbatim). A
        // seam placed at that private helper would emit planar yuv from both
        // arms — plausible-looking garbage rather than a crash, which is the
        // exact defect that nearly shipped in v2.
        debugUpconvertConverter = spyConverter;

        final payload = await decodedRgbaToPixelPayload(
          yuvFrame(8, 8),
          exifOrientation: 1,
          longEdge: 0, // forces the identity short-circuit
        );
        expect(
          payload.rgba.length,
          ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, 8, 8),
          reason: 'short-circuit 1 returned a buffer sized for the SOURCE '
              'format, i.e. unconverted planar yuv',
        );
        expect(
          payload.rgba.every((b) => b == 0xFF),
          isTrue,
          reason: 'short-circuit 1 returned the source bytes, not the '
              "converter's output",
        );

        final fullRes = await decodedRgbaToOrientedFullRes(
          yuvFrame(8, 8),
          exifOrientation: 1, // identity -> short-circuit 2
        );
        expect(
          fullRes.rgba.length,
          ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, 8, 8),
          reason: 'short-circuit 2 returned unconverted planar yuv',
        );
        expect(fullRes.rgba.every((b) => b == 0xFF), isTrue);
        expect(calls.length, 2, reason: 'one conversion per frame');
        fullRes.releaseNative?.call();
      },
    );

    test(
      'TC-1331 (R6): no convert-once memo -- a second call converts again',
      () async {
        debugUpconvertConverter = spyConverter;
        final frame = yuvFrame(8, 8);
        final a = await materialiseRgba(frame);
        final b = await materialiseRgba(frame);
        expect(debugUpconvertCount, 2, reason: 'memo deleted (R6)');
        expect(identical(a, b), isFalse);
        a.releaseNative?.call();
        b.releaseNative?.call();
      },
    );

    test(
      'TC-1332: the converted destination comes from the pool, not from a '
      'fresh Dart allocation',
      () async {
        debugUpconvertConverter = spyConverter;
        final before = pool.debugIdleCount;

        final out = await materialiseRgba(yuvFrame(8, 8));

        // Observed on the REAL pool, not on an injected spy: a Dart-heap
        // destination has no native address and never returns to a free list.
        expect(
          out.nativeAddress,
          isNot(0),
          reason: 'the destination was not a native pooled buffer',
        );
        expect(debugUpconvertPoolAcquireCount, greaterThanOrEqualTo(1));
        out.releaseNative!.call();
        expect(
          pool.debugIdleCount,
          greaterThan(before - 1),
          reason: 'releasing the destination did not return a slot to the '
              'pool, so it did not come from the pool',
        );
      },
    );

    test(
      'TC-1333: pool slots are sized via ceyxOutputFormatByteCount, including '
      'at ODD dimensions where (w/2)*(h/2) under-allocates',
      () async {
        debugUpconvertConverter = spyConverter;
        // 3x3: the contract's ceil form is 9 + 2*(2*2) = 17. The open-coded
        // (w/2)*(h/2) form says 9 + 2*(1*1) = 11 — an under-allocation the
        // converter would read past.
        expect(ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, 3, 3), 17);

        final out = await materialiseRgba(yuvFrame(3, 3));
        expect(calls.single.srcCapacity, 17);
        expect(
          calls.single.dstCapacity,
          ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, 3, 3),
        );
        expect(out.rgba.length, 36);
        out.releaseNative!.call();

        // The discriminator: a source sized by the under-allocating form is
        // REFUSED rather than handed to the converter.
        expect(
          () => materialiseRgba(
            DecodedRgba(
              rgba: Uint8List(11),
              width: 3,
              height: 3,
              format: CeyxOutputFormat.yuv420,
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test(
      'TC-1334: an rgba8 frame passes through the seam untouched (R-B\'s '
      'preserved option is not broken by the flip)',
      () async {
        debugUpconvertConverter = spyConverter;
        final frame = DecodedRgba(
          rgba: Uint8List(8 * 8 * 4),
          width: 8,
          height: 8,
        );
        expect(identical(await materialiseRgba(frame), frame), isTrue);
        expect(debugUpconvertCount, 0);
      },
    );
  });

  group('TC-1341: the family A / family B constant split', () {
    test(
      'TC-1341: the display constant is its OWN constant and the publish '
      'pacer quota reads it, not the decode-output one',
      () {
        // The split is forced by Flutter's API, not chosen: the decode output
        // goes to 1.5 B/px at T15b while `decodeImageFromPixels` still takes
        // RGBA only, so the display buffer stays 4 B/px forever. Sharing one
        // constant would shrink the pacer quota ~2.7x as a silent side effect
        // of T15b's re-derivation, with no test failing.
        final source = File(
          'lib/services/image_pipeline/image_preload_controller.dart',
        ).readAsStringSync();
        expect(
          source.contains('2 * kNominalFullFrameDisplayBytes'),
          isTrue,
          reason: 'the publish pacer quota (family B) must read the DISPLAY '
              'constant',
        );
        expect(
          source.contains('2 * kNominalFullFrameBytes'),
          isFalse,
          reason: 'the pacer quota fell back to the decode-output constant',
        );
        // Today the two are numerically equal — the split is structural, and
        // it is what MAKES T15b able to move one without the other.
        expect(kNominalFullFrameDisplayBytes, isPositive);
      },
    );

    test(
      'TC-1342: the encode/publish tail ceiling is family B — it is sized in '
      'DISPLAY units, because the frames it accounts for are upconverted RGBA',
      () {
        // RULED by the lead 2026-09-20 on T15a's evidence. The tail holds
        // frames that have LEFT the decode lane, and after the flip they reach
        // it through `decodedRgbaToOrientedFullRes`, which returns UPCONVERTED
        // RGBA — so both the ceiling and the real post-decode sizes charged
        // against it are 4 B/px. A ceiling must be in the same units as its
        // charges; leaving this one on the decode-output constant would shrink
        // it ~2.7x the moment T15b re-derives family A, silently.
        //
        // Asserted through the FUNCTION, not by reading the source line, so it
        // fails on the behaviour rather than on a spelling.
        expect(
          encodePublishTailByteBudget(encodeStageWidth: 1),
          kNominalFullFrameDisplayBytes,
        );
        expect(
          encodePublishTailByteBudget(encodeStageWidth: 3),
          3 * kNominalFullFrameDisplayBytes,
        );
        // The discriminator that survives T15b: once family A moves, the two
        // constants differ and this assertion separates them. Today they are
        // numerically equal, so the source-level check below is what carries
        // the weight until then — both are kept deliberately.
        final source = File(
          'lib/services/image_pipeline/frame_bytes.dart',
        ).readAsStringSync();
        final tail = source.substring(
          source.indexOf('int encodePublishTailByteBudget'),
        );
        expect(
          tail.contains('kNominalFullFrameDisplayBytes'),
          isTrue,
          reason: 'the tail ceiling fell back to the decode-output constant',
        );
      },
    );
  });
}
