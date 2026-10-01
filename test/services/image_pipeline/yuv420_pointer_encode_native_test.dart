// Real-dylib integration proof for the 2026-09-20 all-RAW crash fix.
//
// The unit cases in `yuv420_pointer_encode_address_test.dart` fake the
// converter and prove the ADDRESS the pointer arm receives. This file proves
// the consequence: a REAL RAW file, decoded as yuv420 by the REAL native
// library, carried through the REAL materialisation seam, then handed to the
// REAL `ceyx_encode_jpeg_rgba8` through the same pointer entry production
// uses.
//
// HOW THIS FAILS WHEN THE BUG IS PRESENT: not with a red assertion but with a
// SIGSEGV/SIGBUS that kills the test process, because that is precisely what
// the app did -- the encoder reads width*height*4 from a released 1.5 B/px
// slot. A crashed run and a failed run are both non-zero exits; the artifact
// records which, so the two are never conflated.
//
// HOW TO RUN (same mechanism and reason as yuv420_format_loss_test.dart:
// `flutter test` loads no native library):
//
//   DNG_NATIVE_BUILD_DIR=../ceyx/plugin/<os>/Libraries \
//     flutter test test/services/image_pipeline/yuv420_pointer_encode_native_test.dart
//
// A skipped run and a real run differ only in the skip line, so any acceptance
// claim citing this file must cite counts showing the cases PASSING.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:image/image.dart' as img;

final String? _skipReason =
    Platform.environment['DNG_NATIVE_BUILD_DIR'] == null
        ? 'set DNG_NATIVE_BUILD_DIR to ceyx plugin/<os>/Libraries: these '
            'cases decode a real RAW file through the native library'
        : null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Both the originally-reported file and a DIFFERENT vendor's RAW, because
  // the defect was reported for the NEF and then generalised to all RAW. One
  // format passing would not have distinguished the two claims.
  const samples = <String, String>{
    'nikon_z8_he.nef':
        '../ceyx/image_samples/raw_corpus/nikon_z8_he.nef',
    'fuji_xt5.raf':
        '../ceyx/image_samples/raw_corpus/fuji_xt5.raf',
  };

  for (final entry in samples.entries) {
    test(
      'a real yuv420 decode of ${entry.key} survives the REAL pointer JPEG '
      'encode (2026-09-20 all-RAW crash)',
      () async {
        // A missing sample must FAIL, never skip quietly.
        expect(
          File(entry.value).existsSync(),
          isTrue,
          reason: 'sample absent: ${entry.value} — report the absence rather '
              'than passing a case that decoded nothing',
        );

        final service = DngDecoderService();
        service.initialize();
        final extent = service.probeOutputSize(entry.value);
        expect(extent, isNotNull, reason: 'probeOutputSize unavailable');
        final w = extent!.width;
        final h = extent.height;

        final yuvBytes =
            ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h);
        final rgbaBytes =
            ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, w, h);
        // The size gap IS the bug's blast radius. If these were ever equal the
        // case would prove nothing about a format mismatch.
        expect(yuvBytes, lessThan(rgbaBytes));

        final pool = CeyxNativeBufferPool.shared;
        final yuvDst = await pool.acquire(yuvBytes);
        service.decodeIntoPointerFormat(
          entry.value,
          yuvDst.address,
          yuvBytes,
          format: CeyxOutputFormat.yuv420,
        );

        // The production seam, then the production record. `fullRes` is what
        // photo_source.dart forwards from.
        final fullRes = await decodedRgbaToOrientedFullRes(
          DecodedRgba(
            rgba: ffi.Pointer<ffi.Uint8>.fromAddress(
              yuvDst.address,
            ).asTypedList(yuvBytes),
            width: w,
            height: h,
            format: CeyxOutputFormat.yuv420,
            nativeAddress: yuvDst.address,
            releaseNative: () => pool.release(yuvDst),
          ),
          exifOrientation: 1, // identity -> the short-circuit that crashed
        );
        addTearDown(() => fullRes.releaseNative?.call());

        expect(
          fullRes.image,
          isNull,
          reason: 'expected the identity short-circuit, the arm that took the '
              'pointer path in production',
        );
        expect(
          fullRes.nativeAddress,
          isNot(0),
          reason: 'the record must carry the upconvert destination address, '
              'or the pointer arm cannot engage at all',
        );
        expect(
          fullRes.nativeAddress,
          isNot(yuvDst.address),
          reason: 'THE CRASH: the record is still pointing at the yuv420 '
              'source slot, which the seam has already released',
        );
        expect(fullRes.nativeBytes, rgbaBytes);

        // THE CRASHING CALL, for real. Pre-fix this line faulted inside
        // jsimd_extrgbx_ycc_convert_neon and took the process with it.
        final Uint8List jpeg = await CeyxEncodeService().encodeJpegFromNativeRgba(
          rgbaAddress: fullRes.nativeAddress,
          width: fullRes.width,
          height: fullRes.height,
          quality: 90,
          keepAlive: fullRes.nativeKeepAlive is ffi.Finalizable
              ? fullRes.nativeKeepAlive as ffi.Finalizable
              : null,
        );

        expect(jpeg, isNotEmpty);
        final decoded = img.decodeJpg(jpeg);
        expect(decoded, isNotNull, reason: 'the encoder produced bytes that '
            'are not a decodable JPEG');
        expect(decoded!.width, w);
        expect(decoded.height, h);
      },
      skip: _skipReason,
    );
  }
}
