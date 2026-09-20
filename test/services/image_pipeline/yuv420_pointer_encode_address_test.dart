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
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 8;
  const height = 8;

  /// A deliberately RECOGNISABLE fake source address. It is never a real
  /// allocation: if it ever reaches the pointer encoder the test fails, which
  /// is precisely the production crash in miniature.
  const fakeSourceAddress = 0xDEAD0000;

  tearDown(debugResetUpconvertSeam);

  List<PhotoItem> rawItems(List<String> ids) => [
        for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
      ];

  Future<NativeImageResult> needsRawDecodeLoader(
    String path, {
    required ImageRequestPurpose purpose,
    int? targetLongEdge,
  }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

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
      })> runDecodeEncode() async {
    resetReencodeCounters();
    addTearDown(resetReencodeCounters);

    final srcBytes =
        ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, width, height);

    var sourceReleased = false;
    var sourceReleasedBeforeEncode = false;
    int? destinationAddress;
    int? seenAddress;
    var pointerCalls = 0;
    var copyCalls = 0;

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
        sourceReleasedBeforeEncode = sourceReleased;
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
