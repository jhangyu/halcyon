// Regression test for the 2026-09-20 all-RAW crash (mem8 T15a defect).
//
// SYMPTOM: after the decode output flipped to yuv420 (commit 068b17e), opening
// ANY raw file segfaulted the release app inside
// `jsimd_extrgbx_ycc_convert_neon` <- `jpeg_write_scanlines` <-
// `ceyx_encode_jpeg_rgba8`, reached from the pointer-encode arm.
//
// CAUSE: `materialiseRgba` upconverts the planar frame into a DIFFERENT pooled
// slot and releases the yuv420 source. `OrientedFullRes` carried no address, so
// `photo_source.dart` forwarded the PRE-SEAM `DecodedRgba.nativeAddress` --
// a freed, 1.5 B/px buffer -- to a native reader that then read `w*h*4` from
// it. A use-after-free plus a 2.67x overrun.
//
// The existing length guard in `payload_reencoder.dart` could not catch it: it
// measures `fullRes.rgba`, which was correct, while the POINTER pointed
// somewhere else entirely. That is the blindness these cases close.
//
// WHAT WOULD MAKE THESE PASS VACUOUSLY: if the pointer arm stopped running at
// all, `pointerCalls` would be 0 -- so every case asserts the pointer arm DID
// run before asserting what it received. A fix that simply disables the
// zero-copy path fails here, by design.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:image/image.dart' as img;
import '../../support/loader_stubs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 8;
  const height = 8;

  /// A deliberately RECOGNISABLE fake source address. It is never a real
  /// allocation: if it ever reaches the pointer encoder the test fails, which
  /// is precisely the production crash in miniature.
  const fakeSourceAddress = 0xDEAD0000;

  tearDown(debugResetUpconvertSeam);

  Future<void> pumpMicrotasks([int rounds = 24]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Drives a full decode->encode through `ImagePreloadController` with the
  /// decoder emitting PLANAR YUV420, and the upconvert seam faked so no dylib
  /// is needed. Returns what the pointer encoder actually received.
  Future<
      ({
        int pointerCalls,
        int copyCalls,
        int? seenAddress,
        int? destinationAddress,
        bool sourceReleasedBeforeEncode,
        bool destinationReleasedBeforeEncode,
        Object? seenKeepAlive,
      })> runDecodeEncode() async {
    resetReencodeCounters();
    addTearDown(resetReencodeCounters);

    final srcBytes =
        ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, width, height);

    var sourceReleased = false;
    var sourceReleasedBeforeEncode = false;
    var destinationReleased = false;
    var destinationReleasedBeforeEncode = false;
    int? destinationAddress;
    int? seenAddress;
    Object? seenKeepAlive;
    var pointerCalls = 0;
    var copyCalls = 0;

    // Observes the DESTINATION slot's release without suppressing it: the real
    // pool still gets the buffer back, so this is an observation point rather
    // than a behaviour change. Needed because "the address is right" and "the
    // buffer under it is still live" are two different properties, and only
    // the second rules out the use-after-free half of the defect.
    debugUpconvertRelease = (buffer) {
      destinationReleased = true;
      CeyxNativeBufferPool.shared.release(buffer);
    };

    // The REAL shared pool supplies the destination (as every other seam test
    // does), so the address compared below is a genuine allocation rather than
    // a test constant that agrees with the expectation by construction. The
    // converter is the only faked collaborator, and it is handed the
    // destination address -- which is exactly the value under test.
    //
    // Writes opaque white so the identity short-circuit's sampled-opaque
    // assert holds on the CONVERTED buffer.
    debugUpconvertConverter = ({
      required srcAddress,
      required srcCapacity,
      required dstAddress,
      required dstCapacity,
      required width,
      required height,
    }) {
      destinationAddress = dstAddress;
      ffi.Pointer<ffi.Uint8>.fromAddress(
        dstAddress,
      ).asTypedList(dstCapacity).fillRange(0, dstCapacity, 0xFF);
    };

    final controller = ImagePreloadController(
      // OPTION D (2026-09-20 direct-yuv420-encode contract): pinned to null,
      // so these cases keep testing exactly what they were written to test --
      // the PRE-D ordering, where the encode necessarily follows the upconvert
      // and must therefore receive the DESTINATION address.
      //
      // Without this pin the controller's new default would take the deferred
      // planar arm, the direct entry would throw (no dylib in a test process),
      // and these assertions would pass only via the degrade path -- i.e. they
      // would still be green while measuring something else, and would go red
      // the day a dylib IS present. That is the "instrument agrees by
      // accident" failure this file's own header warns about.
      //
      // The D ordering has its own coverage in
      // `yuv420_direct_encode_routing_test.dart`, including the inverted
      // liveness assertion (planar slot LIVE at encode, released after).
      pointerYuv420PayloadEncoder: null,
      imageLoader: needsRawDecodeLoader,
      dngDecoder: (path) async => DecodedRgba(
        rgba: Uint8List(srcBytes),
        width: width,
        height: height,
        format: CeyxOutputFormat.yuv420,
        // The PRE-SEAM address: the one the buggy code forwarded.
        nativeAddress: fakeSourceAddress,
        releaseNative: () => sourceReleased = true,
      ),
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async {
        copyCalls++;
        final frame = img.Image(width: width, height: height);
        return Uint8List.fromList(img.encodeJpg(frame, quality: quality));
      },
      pointerPayloadEncoder: ({
        required nativeAddress,
        required width,
        required height,
        required quality,
        keepAlive,
      }) async {
        pointerCalls++;
        seenAddress = nativeAddress;
        seenKeepAlive = keepAlive;
        sourceReleasedBeforeEncode = sourceReleased;
        destinationReleasedBeforeEncode = destinationReleased;
        final frame = img.Image(width: width, height: height);
        return Uint8List.fromList(img.encodeJpg(frame, quality: quality));
      },
      decodeLaneWidth: 1,
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(32, 32);

    await controller.preloadImages(
      items: rawItems(['a']),
      selectedItemId: 'a',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();

    return (
      pointerCalls: pointerCalls,
      copyCalls: copyCalls,
      seenAddress: seenAddress,
      destinationAddress: destinationAddress,
      sourceReleasedBeforeEncode: sourceReleasedBeforeEncode,
      destinationReleasedBeforeEncode: destinationReleasedBeforeEncode,
      seenKeepAlive: seenKeepAlive,
    );
  }

  group('yuv420 pointer-encode address (2026-09-20 all-RAW crash)', () {
    test(
      'the pointer encoder receives the UPCONVERT DESTINATION address, never '
      'the released yuv420 source',
      () async {
        final r = await runDecodeEncode();

        // Guard against a vacuous pass: the zero-copy arm must still be live.
        expect(
          r.pointerCalls,
          1,
          reason: 'the pointer arm did not run, so the address assertions '
              'below would pass vacuously; a fix that merely disables the '
              'zero-copy path is not the fix',
        );
        expect(
          r.seenAddress,
          isNot(fakeSourceAddress),
          reason: 'THE CRASH: the pre-seam yuv420 source address reached the '
              'native encoder, which then read width*height*4 from a '
              '1.5 B/px buffer that materialiseRgba had already released',
        );
        expect(
          r.destinationAddress,
          isNotNull,
          reason: 'the seam never acquired an rgba8 destination',
        );
        expect(
          r.seenAddress,
          r.destinationAddress,
          reason: 'the encoder must read the buffer fullRes.rgba actually '
              'aliases -- the upconvert destination',
        );
      },
    );

    test(
      'the source slot really was released before the encode ran, so '
      'forwarding it would have been a use-after-free',
      () async {
        final r = await runDecodeEncode();

        // This is what makes the defect a USE-AFTER-FREE and not merely a
        // size mismatch. Pinned so a future change to the seam's release point
        // cannot quietly downgrade the severity this test guards.
        expect(
          r.sourceReleasedBeforeEncode,
          isTrue,
          reason: 'if the source were still live the bug would be a mere '
              'overrun; it is released here, so the forwarded address was '
              'dangling as well as wrongly sized',
        );
      },
    );

    // H1's addendum: the overrun had TWO independent causes -- wrong layout
    // (1.5 vs 4 B/px) AND use-after-free. Forwarding the destination address
    // fixes both ONLY IF the destination is still live when the encoder reads
    // it. "The address is right" and "the buffer under it exists" are separate
    // properties; a fix that merely re-derived byte counts would leave a
    // rarer, load-dependent crash. Asserted here so that distinction is
    // mechanical rather than argued.
    test(
      'the DESTINATION slot is still live at encode time, and its keep-alive '
      'travels with the address',
      () async {
        final r = await runDecodeEncode();

        expect(
          r.pointerCalls,
          1,
          reason: 'the pointer arm must have run for liveness to mean '
              'anything here',
        );
        expect(
          r.destinationReleasedBeforeEncode,
          isFalse,
          reason: 'the upconvert destination was returned to the pool BEFORE '
              'the encoder read it -- the same use-after-free as the original '
              'defect, merely moved to the other buffer',
        );
        expect(
          r.seenKeepAlive,
          isNotNull,
          reason: 'the address travelled without its keep-alive, so nothing '
              'holds the slot for the duration of the encode',
        );
      },
    );

    test(
      'a stated native capacity that disagrees with width*height*4 demotes to '
      'the byte encoder instead of faulting',
      () async {
        var pointerCalls = 0;
        var copyCalls = 0;
        resetReencodeCounters();
        addTearDown(resetReencodeCounters);

        // The hardening H1 asked for: the guard now checks the POINTER's
        // capacity, not a different buffer's length. Sized as yuv420 while the
        // extent claims rgba8 -- exactly the production mismatch.
        final payload = await reencodePayload(
          encoder: (rgba, {required width, required height, required quality}) async {
            copyCalls++;
            return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
          },
          fallback: () async => throw StateError('must not fall back'),
          fullRes: (
            rgba: Uint8List(width * height * 4),
            width: width,
            height: height,
          ),
          pointerEncoder: ({
            required nativeAddress,
            required width,
            required height,
            required quality,
            keepAlive,
          }) async {
            pointerCalls++;
            return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
          },
          nativeAddress: fakeSourceAddress,
          nativeBytes:
              ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, width, height),
        );

        expect(
          pointerCalls,
          0,
          reason: 'a buffer too small for width*height*4 must never reach a '
              'native reader that trusts those dimensions',
        );
        expect(copyCalls, 1, reason: 'it must still encode, via the byte arm');
        expect(payload, isNotNull);
      },
    );
  });
}
