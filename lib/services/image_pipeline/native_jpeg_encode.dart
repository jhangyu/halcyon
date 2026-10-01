import 'dart:ffi' show Finalizable;
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart' show CeyxEncodeService;

/// Production binding for [PayloadEncoder] (user ruling 2026-08-30, after the
/// Task 0 STOP gate): pure-Dart `encodeJpegFromRgba` measured 4102ms median at
/// q80, 8x over the 500ms lane-budget gate. This calls ceyx's native
/// libjpeg-turbo encoder instead (in-process gate median 89ms). The pure-Dart
/// encoder is UNCHANGED and remains the sidebar codec's encoder and the
/// default test/seam binding -- only the controller's default wiring changes.
Future<Uint8List> encodeJpegNative(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) {
  return CeyxEncodeService().encodeJpegNative(
    rgba,
    width: width,
    height: height,
    quality: quality,
  );
}

/// Production binding for [PointerPayloadEncoder] (R2b, gc-remediation
/// 2026-09-06): the WP3/WP3b pointer entry, wired end-to-end so a
/// native-backed identity-path decode skips the `TransferableTypedData.
/// fromList` copy [encodeJpegNative] pays. [keepAlive] arrives as `Object?`
/// (the `PointerPayloadEncoder` typedef, `payload_reencoder.dart`, is
/// decoder-package-agnostic by design -- E-WP3b); ceyx's entry point wants a
/// `Finalizable` specifically.
///
/// AMENDED 2026-09-20 (all-RAW crash fix). This used to be a HARD cast, on the
/// stated invariant that a non-zero `nativeAddress` always travelled with a
/// `DngImage` handle. THAT INVARIANT NO LONGER HOLDS: the buffer under the
/// address can be a pooled slot produced by `materialiseRgba` (which survives
/// on the degrade and non-yuv420 arms), whose keep-alive is a
/// `CeyxNativeBuffer` -- not `Finalizable`. The identity path no longer
/// materialises at all (q70-decouple), so it never reaches here with one.
/// A hard cast throws `TypeError` on every such frame, and because the
/// pointer call sits inside `reencodePayload`'s try/degrade that throw would be
/// SWALLOWED into a byte-arm fallback: the zero-copy path silently off, nothing
/// red. Hence the `is` test.
///
/// Passing null for the pooled destination is safe, and not merely tolerable:
/// a pooled slot's lifetime is governed by explicit release
/// (`OrientedFullRes.releaseNative`), not by finalization, and the record that
/// owns it is held by `PhotoSource.encodePhase` across this await -- so the
/// slot is reachable for the whole encode. `Finalizable` is what the DngImage
/// handle needs; the pool slot does not need it and cannot supply it.
Future<Uint8List> encodeJpegFromNativeRgba({
  required int nativeAddress,
  required int width,
  required int height,
  required int quality,
  Object? keepAlive,
}) {
  return CeyxEncodeService().encodeJpegFromNativeRgba(
    rgbaAddress: nativeAddress,
    width: width,
    height: height,
    quality: quality,
    keepAlive: keepAlive is Finalizable ? keepAlive : null,
  );
}

/// Production binding for [PointerYuv420PayloadEncoder] (2026-09-20
/// direct-yuv420-encode contract, Option D).
///
/// Same SOFT `is Finalizable` test as its rgba8 sibling above, and for the
/// same reason: the planar frame's keep-alive is whatever the decoder handed
/// back, which is a `CeyxNativeBuffer` for a pooled slot and NOT
/// `Finalizable`. A hard cast would throw `TypeError`, and because the caller
/// wraps this in a try/degrade that throw would be swallowed into the byte
/// arm -- the zero-copy path silently off, nothing red. That exact defect
/// already happened once on the rgba8 arm (see its dartdoc).
///
/// `CeyxFormatUnsupportedException` from a dylib predating the entry is NOT
/// caught here: the caller degrades and logs it, so the reason survives.
Future<Uint8List> encodeJpegFromNativeYuv420({
  required int nativeAddress,
  required int srcCapacity,
  required int width,
  required int height,
  required int quality,
  Object? keepAlive,
}) {
  return CeyxEncodeService().encodeJpegFromNativeYuv420(
    srcAddress: nativeAddress,
    srcCapacity: srcCapacity,
    width: width,
    height: height,
    quality: quality,
    keepAlive: keepAlive is Finalizable ? keepAlive : null,
  );
}
