import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';
import 'package:halcyon_flutter/services/image_pipeline/frame_bytes.dart';

/// mem8 T15a (SR-12) — the yuv420 flip's Halcyon-side seam, default, constant
/// split and R-J capability gate.
///
/// KNOWN COVERAGE GAP, recorded here rather than silently dropped, exactly as
/// ceyx did for its own equivalent. The "real pre-yuv420 dylib" version of the
/// absence cases DOES NOT EXIST and must not be specified: see
/// `../ceyx/plugin/test/raw_symbol_absent_test.dart:12-38`, which records that
/// the pinned snapshot at `../tmp/old-dylib-raw/` is gitignored, was never
/// committed, predates every commit in the tree, cannot be regenerated without
/// a pre-Phase-17 checkout plus a full native rebuild, and had become a
/// permanent silent skip that read green. Those cases were deleted there for
/// that reason. The same file records why no substitute dylib works:
/// `DngNativeBindings`' constructor has UNGUARDED lookups that throw on any
/// library lacking the always-present entries, so nothing available can stand
/// in for "has everything except the new pair".
///
/// The absence cases below therefore drive ceyx's own forced-absence seam.
/// NOTE ON ITS NAME: the mem8 v3 plan (T15a.4b) names that seam
/// `debugForceYuv420SymbolsAbsent`. T14 shipped it as
/// `CeyxDecodePool.debugYuv420Available` (a nullable bool override read by the
/// production resolution path at `decode_pool.dart:847`). Same seam, different
/// name; recorded so the next reader does not re-derive the discrepancy and
/// conclude T14 is missing.
void main() {
  final pool = CeyxNativeBufferPool.shared;

  tearDown(() {
    debugResetUpconvertSeam();
    debugYuv420GateProbe = null;
    debugResetYuv420Gate();
    CeyxDecodePool.debugYuv420Available = null;
  });

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
      'TC-1331: a twice-read decode converts once',
      () async {
        debugUpconvertConverter = spyConverter;
        final frame = yuvFrame(8, 8);

        // The production shape this pins: the deferred encode path and a
        // display fallback both read the SAME decoded frame.
        final a = await decodedRgbaToOrientedFullRes(
          frame,
          exifOrientation: 1,
        );
        final b = await decodedRgbaToPixelPayload(
          frame,
          exifOrientation: 1,
          longEdge: 0,
        );

        expect(
          debugUpconvertCount,
          1,
          reason: 'the second read paid for a second upconvert; step 5 '
              'requires the converted buffer to be reused',
        );
        expect(calls.length, 1);
        expect(a.rgba.every((v) => v == 0xFF), isTrue);
        expect(b.rgba.every((v) => v == 0xFF), isTrue);
        a.releaseNative?.call();
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

  group('TC-1335..1339: the R-J capability gate', () {
    const staleLibrary = '/Users/somebody/Halcyon.app/libdng_decoder.dylib';
    const failure = CeyxFormatUnsupportedException(
      format: CeyxOutputFormat.yuv420,
      missingSymbol: 'ceyx_yuv420_to_rgba8',
      libraryPath: staleLibrary,
    );

    test(
      'TC-1335: an absent format symbol throws CeyxFormatUnsupportedException '
      'at pool configuration, not at first decode',
      () {
        debugYuv420GateProbe = () => failure;
        expect(
          ensureHalcyonDecodePoolConfigured,
          throwsA(isA<CeyxFormatUnsupportedException>()),
          reason: 'the gate returned a null/bool/degraded decoder instead of '
              'raising R-J\'s hard typed failure',
        );
      },
    );

    test(
      'TC-1336: the thrown type IS the plugin\'s frozen '
      'CeyxFormatUnsupportedException — Halcyon does not invent its own',
      () {
        debugYuv420GateProbe = () => failure;
        Object? caught;
        try {
          ensureHalcyonDecodePoolConfigured();
        } catch (e) {
          caught = e;
        }
        expect(caught, same(failure));
        expect(caught.runtimeType, CeyxFormatUnsupportedException);
      },
    );

    test(
      'TC-1337: the type declares EXACTLY the three contract fields — fails '
      'if one is added OR removed',
      () {
        // A frozen shape that nothing checks is a comment. ceyx carries the
        // mirror of this assertion; Halcyon carries its own rather than
        // assuming the other side covers it, because the contract has four
        // consumers and each would be individually reasonable in adding one
        // more field. The fourth field explicitly ruled OUT is the expected
        // pin digest: it is already authoritative in
        // `scripts/ceyx_release_pin.json`, and copying it here would create a
        // second source of truth inside a message nobody re-reads.
        final declared = _declaredFieldsOf(
          File('../ceyx/plugin/lib/src/codec_format.dart'),
          'class CeyxFormatUnsupportedException',
        );
        expect(
          declared,
          unorderedEquals(<String>['format', 'missingSymbol', 'libraryPath']),
          reason: 'the frozen three-field shape changed; T14 and T15a adopt '
              'the field set TOGETHER, neither side on its own authority',
        );
        // And the shape is live, not merely declared.
        expect(failure.format, CeyxOutputFormat.yuv420);
        expect(failure.missingSymbol, 'ceyx_yuv420_to_rgba8');
        expect(failure.libraryPath, staleLibrary);
      },
    );

    test(
      'TC-1338: the typed failure is NOT RawUnavailableException — a stale '
      'pin and a deliberately RAW-less build need opposite responses',
      () {
        debugYuv420GateProbe = () => failure;
        expect(
          ensureHalcyonDecodePoolConfigured,
          throwsA(isNot(isA<RawUnavailableException>())),
        );
      },
    );

    test(
      'TC-1339: nothing decodes after the gate fires',
      () async {
        debugYuv420GateProbe = () => failure;
        // Both production decode entry points call the gate FIRST, so neither
        // can reach the pool. A throw plus a fallback that still produced
        // pixels would be the silent degradation R-J bans.
        await expectLater(
          decodeDngFull('/nonexistent.dng'),
          throwsA(isA<CeyxFormatUnsupportedException>()),
        );
        await expectLater(
          decodeDngFullOriented('/nonexistent.dng', exifOrientation: 1),
          throwsA(isA<CeyxFormatUnsupportedException>()),
        );
      },
    );

    test(
      'TC-1340: an rgba8 request still succeeds while the yuv420 symbols are '
      'forced absent — the gate fires on the right condition, not on any',
      () async {
        // Deliberately IN THE SAME FILE as TC-1335/1339 so the two rules
        // cannot drift apart in separate files.
        CeyxDecodePool.debugYuv420Available = false;
        debugUpconvertConverter = spyConverter;
        final rgba8 = DecodedRgba(
          rgba: Uint8List(4 * 4 * 4),
          width: 4,
          height: 4,
        );
        final out = await materialiseRgba(rgba8);
        expect(
          identical(out, rgba8),
          isTrue,
          reason: 'the gate over-fired and broke the preserved rgba8 option',
        );
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

/// Reads the constructor field set of [className] straight from ceyx's source,
/// so "exactly three fields" is asserted against the DECLARATION rather than
/// against a Halcyon-side restatement of it.
List<String> _declaredFieldsOf(File file, String className) {
  final text = file.readAsStringSync();
  final start = text.indexOf(className);
  if (start < 0) {
    throw StateError('$className not found in ${file.path}');
  }
  final ctorStart = text.indexOf('({', start);
  final ctorEnd = text.indexOf('});', ctorStart);
  final body = text.substring(ctorStart + 2, ctorEnd);
  return RegExp(r'this\.([A-Za-z0-9_]+)')
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toList();
}
