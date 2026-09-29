// Option D (2026-09-20 direct-yuv420-encode contract, AC3): the pointer-encode
// arm dispatches by DECODE FORMAT.
//
//   yuv420 decode -> `ceyx_encode_jpeg_yuv420`, fed the LIVE planar buffer,
//                    with NO `materialiseRgba` upconvert ahead of it;
//   rgba8  decode -> the pre-existing rgba8 pointer entry, unchanged.
//
// WHY THE ORDER IS THE PROPERTY UNDER TEST. `materialiseRgba` releases the
// planar source slot as soon as it has converted it
// (`decoded_rgba_image_provider.dart:265-272`). So "encode first" is not a
// tuning choice -- it is the only window in which the planar bytes exist.
// Encoding after the seam hands a freed slot to a native reader, which is the
// 2026-09-20 all-RAW crash (`docs/logs/2026-09-20/h2-root-cause.md`).
//
// RELATIONSHIP TO `yuv420_pointer_encode_address_test.dart`: that file pins the
// PRE-D contract, where the encode necessarily ran after the upconvert and so
// had to receive the DESTINATION address. Option D removes that ordering, so
// its "source released before encode" assertion inverts here BY DESIGN -- see
// the `the planar slot is LIVE at encode and released AFTER it` case, which
// carries the equivalent use-after-free tripwire in the new ordering.
//
// VACUOUS-PASS GUARD: every case asserts the arm it cares about ACTUALLY RAN
// before asserting what it received. A change that silently disables the
// zero-copy path fails here by design -- both defects this campaign already
// produced were exactly that shape.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 8;
  const height = 8;

  tearDown(debugResetUpconvertSeam);

  List<PhotoItem> rawItems() => [
        PhotoItem(id: 'a', files: [File('/tmp/a.dng')]),
      ];

  Future<NativeImageResult> loader(
    String path, {
    required ImageRequestPurpose purpose,
    int? targetLongEdge,
  }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

  Future<void> pumpMicrotasks([int rounds = 40]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Uint8List jpegBytes() {
    final frame = img.Image(width: width, height: height);
    return Uint8List.fromList(img.encodeJpg(frame, quality: 70));
  }

  /// Drives one decode->encode->publish through the real controller.
  ///
  /// [yuv420] picks the decode format. [yuv420Throws] makes the direct entry
  /// fail the way a stale dylib does (`CeyxFormatUnsupportedException`).
  Future<
      ({
        int yuv420Calls,
        int rgba8Calls,
        int byteCalls,
        int upconvertsBeforeEncode,
        int upconvertsTotal,
        int? seenAddress,
        int? seenCapacity,
        Object? seenKeepAlive,
        bool planarLiveAtEncode,
        bool planarReleasedAfterEncode,
        int fallbacks,
      })> run({
    required bool yuv420,
    bool yuv420Throws = false,
    bool yuv420Unavailable = false,
  }) async {
    resetReencodeCounters();
    addTearDown(resetReencodeCounters);

    var planarReleased = false;
    var planarLiveAtEncode = false;
    var planarReleasedAfterEncode = false;
    var upconvertsBeforeEncode = 0;
    var yuv420Calls = 0;
    var rgba8Calls = 0;
    var byteCalls = 0;
    int? seenAddress;
    int? seenCapacity;
    Object? seenKeepAlive;
    var encodeRan = false;

    final srcBytes = yuv420
        ? ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, width, height)
        : width * height * 4;

    // A REAL native allocation, so the address the encoder is handed is a
    // genuine one rather than a constant that agrees by construction.
    final slot = await CeyxNativeBufferPool.shared.acquire(srcBytes);
    addTearDown(() => CeyxNativeBufferPool.shared.release(slot));
    final planarView = ffi.Pointer<ffi.Uint8>.fromAddress(
      slot.address,
    ).asTypedList(srcBytes);
    if (!yuv420) planarView.fillRange(0, srcBytes, 0xFF);

    debugUpconvertConverter = ({
      required srcAddress,
      required srcCapacity,
      required dstAddress,
      required dstCapacity,
      required width,
      required height,
    }) {
      if (!encodeRan) upconvertsBeforeEncode++;
      ffi.Pointer<ffi.Uint8>.fromAddress(
        dstAddress,
      ).asTypedList(dstCapacity).fillRange(0, dstCapacity, 0xFF);
    };

    final controller = ImagePreloadController(
      imageLoader: loader,
      dngDecoder: (path) async => DecodedRgba(
        rgba: planarView,
        width: width,
        height: height,
        format: yuv420 ? CeyxOutputFormat.yuv420 : CeyxOutputFormat.rgba8,
        nativeAddress: slot.address,
        nativeKeepAlive: slot,
        releaseNative: () => planarReleased = true,
      ),
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async {
        byteCalls++;
        return jpegBytes();
      },
      pointerPayloadEncoder: ({
        required nativeAddress,
        required width,
        required height,
        required quality,
        keepAlive,
      }) async {
        rgba8Calls++;
        encodeRan = true;
        return jpegBytes();
      },
      pointerYuv420PayloadEncoder: yuv420Unavailable
          ? null
          : ({
              required nativeAddress,
              required srcCapacity,
              required width,
              required height,
              required quality,
              keepAlive,
            }) async {
              yuv420Calls++;
              encodeRan = true;
              seenAddress = nativeAddress;
              seenCapacity = srcCapacity;
              seenKeepAlive = keepAlive;
              planarLiveAtEncode = !planarReleased;
              if (yuv420Throws) {
                throw const CeyxFormatUnsupportedException(
                  format: CeyxOutputFormat.yuv420,
                  missingSymbol: 'ceyx_encode_jpeg_yuv420',
                  libraryPath: kCeyxNoLibraryLoaded,
                );
              }
              return jpegBytes();
            },
      decodeLaneWidth: 1,
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(32, 32);

    await controller.preloadImages(
      items: rawItems(),
      selectedItemId: 'a',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();
    planarReleasedAfterEncode = planarReleased;

    return (
      yuv420Calls: yuv420Calls,
      rgba8Calls: rgba8Calls,
      byteCalls: byteCalls,
      upconvertsBeforeEncode: upconvertsBeforeEncode,
      upconvertsTotal: debugUpconvertCount,
      seenAddress: seenAddress,
      seenCapacity: seenCapacity,
      seenKeepAlive: seenKeepAlive,
      planarLiveAtEncode: planarLiveAtEncode,
      planarReleasedAfterEncode: planarReleasedAfterEncode,
      fallbacks: reencodeFallbacks,
    );
  }

  group('AC3 routing by decode format', () {
    // TC-1375
    test('yuv420 decode takes the yuv420 entry, with NO materialise ahead of '
        'it', () async {
      final r = await run(yuv420: true);

      expect(r.yuv420Calls, 1, reason: 'the direct planar arm did not run, so '
          'every assertion below would pass vacuously');
      expect(r.rgba8Calls, 0, reason: 'the rgba8 pointer entry must not see a '
          'planar frame -- it would read w*h*4 from a 1.5 B/px buffer');
      expect(r.byteCalls, 0, reason: 'a healthy planar frame must not degrade '
          'to the copying byte arm');
      expect(
        r.upconvertsBeforeEncode,
        0,
        reason: 'THE CONTRACT (AC3): an upconvert ran BEFORE the encode, so '
            'the encode arm is still paying for a materialise it does not '
            'need',
      );
      expect(r.fallbacks, 0, reason: 'a silent degrade would leave the '
          'zero-copy path off with nothing red');
    });

    // TC-1376
    test('the encoder is fed the LIVE planar buffer: address, real capacity, '
        'and its keep-alive', () async {
      final r = await run(yuv420: true);

      expect(r.yuv420Calls, 1);
      expect(
        r.seenCapacity,
        ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, width, height),
        reason: 'the REAL allocation length must reach the ABI, never a '
            'recomputed w*h*1.5 -- the native -412 check is only meaningful '
            'when handed the true figure',
      );
      expect(r.seenAddress, isNotNull);
      expect(r.seenAddress, isNot(0));
      expect(
        r.seenKeepAlive,
        isNotNull,
        reason: 'the address travelled without its keep-alive, so nothing '
            'holds the slot for the duration of the encode',
      );
    });

    // The use-after-free tripwire, in Option D's ordering. This REPLACES (and
    // inverts) the pre-D assertion that the source was already released at
    // encode time: under D the planar slot must still be LIVE, and must come
    // back only once the seam has consumed it.
    // TC-1377
    test('the planar slot is LIVE at encode and released AFTER it', () async {
      final r = await run(yuv420: true);

      expect(r.yuv420Calls, 1, reason: 'liveness means nothing if the arm '
          'never ran');
      expect(
        r.planarLiveAtEncode,
        isTrue,
        reason: 'USE-AFTER-FREE: the planar slot was already back in the pool '
            'when the native encoder read it. This is the 2026-09-20 crash '
            'with the buffers swapped',
      );
      expect(
        r.planarReleasedAfterEncode,
        isTrue,
        reason: 'the planar slot never came back to the pool -- Option D '
            'leaks one full planar frame per decode',
      );
    });

    // TC-1378
    test('rgba8 decode still takes the rgba8 entry', () async {
      final r = await run(yuv420: false);

      expect(r.rgba8Calls, 1, reason: 'the pre-existing rgba8 pointer arm '
          'regressed');
      expect(r.yuv420Calls, 0, reason: 'an rgba8 frame must never reach the '
          'planar entry');
      expect(r.byteCalls, 0);
    });
  });

  group('silent-degradation gate', () {
    // TC-1379
    test('a stale dylib degrades LOUDLY to the byte arm, never a silent '
        'no-op', () async {
      final r = await run(yuv420: true, yuv420Throws: true);

      expect(r.yuv420Calls, 1, reason: 'the direct arm must have been TRIED');
      expect(
        r.byteCalls + r.rgba8Calls,
        greaterThan(0),
        reason: 'CeyxFormatUnsupportedException degraded to nothing at all -- '
            'the item has no payload and the failure is invisible',
      );
      expect(
        r.fallbacks,
        greaterThan(0),
        reason: 'the degrade left no trace in reencodeFallbacks, so a build '
            'whose dylib lacks the symbol looks exactly like a healthy one',
      );
      expect(
        r.upconvertsTotal,
        greaterThan(0),
        reason: 'the display path still needs its RGBA after a degrade',
      );
    });

    // TC-1380
    test('no yuv420 encoder bound at all: pre-D behaviour, still encodes',
        () async {
      final r = await run(yuv420: true, yuv420Unavailable: true);

      expect(r.yuv420Calls, 0);
      expect(
        r.rgba8Calls + r.byteCalls,
        greaterThan(0),
        reason: 'with no direct entry the frame must still reach an encoder',
      );
    });
  });

  // Lead's addition: an encode-arm failure must degrade loudly, never leave a
  // pending future. The decode-side equivalent is already covered by
  // photo_source_test.dart:651.
  // TC-1381
  test('an encode-arm failure resolves the load instead of stranding it',
      () async {
    final r = await run(yuv420: true, yuv420Throws: true).timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('the load never completed -- an encode-arm '
          'failure produced a pending future, i.e. an eternal spinner'),
    );
    expect(r.fallbacks, greaterThan(0));
  });

  // R1 / R8 (q70-decouple, 2026-09-29): the planar encode arm at PhotoSource
  // level, below the controller, so the outcome record itself is observable.
  group('R1 planar-only encode outcome', () {
    Future<
        ({
          SourceOutcome outcome,
          int releases,
          PhotoSource source,
        })> encodeDeferred({required bool encoderThrows}) async {
      resetReencodeCounters();
      addTearDown(resetReencodeCounters);
      final srcBytes =
          ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, width, height);
      final slot = await CeyxNativeBufferPool.shared.acquire(srcBytes);
      addTearDown(() => CeyxNativeBufferPool.shared.release(slot));
      final view = ffi.Pointer<ffi.Uint8>.fromAddress(
        slot.address,
      ).asTypedList(srcBytes);
      debugUpconvertConverter = ({
        required srcAddress,
        required srcCapacity,
        required dstAddress,
        required dstCapacity,
        required width,
        required height,
      }) {
        ffi.Pointer<ffi.Uint8>.fromAddress(
          dstAddress,
        ).asTypedList(dstCapacity).fillRange(0, dstCapacity, 0xFF);
      };
      var releases = 0;
      final source = PhotoSource(
        loader: loader,
        dngDecoder: (path) async => DecodedRgba(
          rgba: view,
          width: width,
          height: height,
          format: CeyxOutputFormat.yuv420,
          nativeAddress: slot.address,
          nativeKeepAlive: slot,
          releaseNative: () => releases++,
        ),
        payloadEncoder: (rgba, {required width, required height, required quality}) async =>
            jpegBytes(),
        pointerPayloadEncoder: ({
          required nativeAddress,
          required width,
          required height,
          required quality,
          keepAlive,
        }) async => jpegBytes(),
        pointerYuv420PayloadEncoder: ({
          required nativeAddress,
          required srcCapacity,
          required width,
          required height,
          required quality,
          keepAlive,
        }) async {
          if (encoderThrows) throw StateError('no symbol');
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      final decode = await source.decodePhase('/tmp/a.dng', longEdge: 2800);
      expect(decode.pendingPlanarEncode, isNotNull,
          reason: 'deferral did not engage; test would be vacuous');
      final outcome = await source.encodePhase(decode);
      return (outcome: outcome, releases: releases, source: source);
    }

    test('R1: planar encode success returns payload-only, zero upconverts, '
        'planar slot released exactly once', () async {
      final r = await encodeDeferred(encoderThrows: false);

      expect(r.outcome.payload, isNotNull);
      expect(r.outcome.fullRes, isNull, reason: 'R1: no RGBA on this path');
      expect(debugUpconvertCount, 0);
      expect(r.releases, 1, reason: 'exactly one release, not zero and not two');
    });

    test('R8: encoder failure still yields a payload, converting exactly once',
        () async {
      final r = await encodeDeferred(encoderThrows: true);

      expect(r.outcome.payload, isNotNull);
      expect(r.outcome.fullRes, isNotNull,
          reason: 'degrade arm still needs RGBA');
      expect(debugUpconvertCount, 1, reason: 'not 2 -- no memo, no double convert');
      expect(reencodeFallbacks, 1);
    });
  });
}
