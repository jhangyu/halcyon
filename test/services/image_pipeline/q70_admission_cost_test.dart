import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

// TC-1394..TC-1396 (q70-decouple AC5). Replaces TC-1387, whose subject
// (`deferredUpconvertPeakBytes`) was deleted with the converter it sized for.
void main() {
  DecodedRgba planarFrame(int w, int h) => DecodedRgba(
    rgba: Uint8List(ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h)),
    width: w,
    height: h,
    format: CeyxOutputFormat.yuv420,
    nativeAddress: 1,
  );

  SourceDecode deferredDecodeOf(DecodedRgba frame) => (
    encodedPayload: null,
    pixelFallback: null,
    rawDecodeRan: true,
    fullRes: null,
    observedCost: SourceCost.expensive,
    deferred: false,
    exifOrientation: null,
    failureCode: null,
    nativeAddress: 1,
    nativeKeepAlive: null,
    pendingPlanarEncode: (frame: frame, exifOrientation: 1, longEdge: 2800),
  );

  SourceDecode nonDeferredDecode() => (
    encodedPayload: null,
    pixelFallback: null,
    rawDecodeRan: false,
    fullRes: null,
    observedCost: SourceCost.cheap,
    deferred: false,
    exifOrientation: null,
    failureCode: null,
    nativeAddress: 0,
    nativeKeepAlive: null,
    pendingPlanarEncode: null,
  );

  test('TC-1394 (AC5): a deferred decode is charged its PLANAR bytes', () {
    final frame = planarFrame(100, 50);
    expect(
      ImagePreloadController.deferredPlanarBytes(deferredDecodeOf(frame)),
      frame.rgba.lengthInBytes,
    );
  });

  test('TC-1395 (AC5): the 5.5 B/px upconvert charge is GONE', () {
    final frame = planarFrame(100, 50);
    expect(
      ImagePreloadController.deferredPlanarBytes(deferredDecodeOf(frame)),
      isNot(frame.rgba.lengthInBytes + 100 * 50 * 4),
      reason:
          'the converter that held both buffers no longer runs (T1); '
          'charging for its destination reserves ~27% of the ledger against '
          'a buffer that is never allocated',
    );
  });

  test('TC-1396 (AC5): SCOPE GUARD — non-deferred sizing is untouched', () {
    expect(
      ImagePreloadController.deferredPlanarBytes(nonDeferredDecode()),
      isNull,
    );
  });
}
