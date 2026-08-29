import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting, debugPrint;
import 'package:image/image.dart' as img;

import '../../models/supported_photo_formats.dart';
import 'dng_decode_contract.dart';
import 'dng_decode_service.dart';
import 'dng_embedded_jpeg_extractor.dart';
import 'heif_decode_service.dart';

/// One production implementation of [DngFullDecoder]/[DngSizedDecoder] for
/// every format Halcyon can turn into RGBA, so that `dart_image_loader.dart`
/// and `photo_source.dart` need no format knowledge beyond the registry
/// predicate. Routing:
///
///   .heic/.heif -> the native libheif route in ceyx (phase 2)
///   .tif/.tiff  -> package:image decodeTiff on a worker isolate
///   RAW         -> the existing Ceyx engine decode (unchanged)
///   otherwise   -> UnsupportedError
///
/// The `UnsupportedError` is a designed degradation path, not an accident:
/// `photo_source.dart`'s step-3b catch turns any decoder throw into the
/// uniform permanent miss, and the sidebar's catch turns it into a permanent
/// thumbnail miss. The D3 `kNoNativeDecoderCode` state stays reserved for a
/// null decoder and is unreachable from here.

/// Injection seam for the pure-CPU half of the TIFF arm. Production always
/// uses [decodeTiffBytes]; tests substitute a spy to prove the decoded-pixel
/// ceiling is checked BEFORE a decode is attempted.
typedef TiffBytesDecoder =
    Future<DecodedRgba> Function(Uint8List bytes, {int? maxDim});

/// Decodes [bytes] as TIFF on a worker isolate and returns RGBA8.
///
/// Page 0 only (`decodeTiff`'s default frame): a multi-page fax TIFF shows its
/// first page. 16/32-bit samples are down-converted to 8-bit by `getBytes`,
/// which is what everything downstream of [DecodedRgba] takes anyway.
///
/// [maxDim] > 0 caps the LONG edge, aspect ratio preserved; it is a request,
/// not a guarantee (see [DngSizedDecoder]) — callers read the returned
/// dimensions back.
Future<DecodedRgba> decodeTiffBytes(Uint8List bytes, {int? maxDim}) async {
  // Only sendable values cross the isolate boundary: a Uint8List and an int?.
  final decoded =
      await Isolate.run<({Uint8List rgba, int width, int height})?>(() {
    final frame0 = img.decodeTiff(bytes);
    // Null covers "not a TIFF", truncated data, and any compression
    // package:image refuses (CCITT G3/G4, JPEG2000-in-TIFF, old-style
    // JPEG-in-TIFF). No fallback chain: it becomes an ordinary decode failure.
    if (frame0 == null) return null;
    var frame = frame0;
    if (maxDim != null &&
        maxDim > 0 &&
        (frame.width > maxDim || frame.height > maxDim)) {
      frame = img.copyResize(
        frame,
        width: frame.width >= frame.height ? maxDim : null,
        height: frame.height > frame.width ? maxDim : null,
        interpolation: img.Interpolation.linear,
      );
    }
    return (
      rgba: frame.getBytes(order: img.ChannelOrder.rgba),
      width: frame.width,
      height: frame.height,
    );
  });
  if (decoded == null) {
    throw StateError(
      'TIFF_DECODE_FAILED: package:image could not decode this TIFF',
    );
  }
  final expectedLength = decoded.width * decoded.height * 4;
  if (decoded.rgba.length != expectedLength) {
    // Mirrors decodeDngFull's check: PixelPayload's assert and
    // _imageFromPixels' invariant both depend on this holding.
    throw StateError(
      'TIFF length mismatch: rgba.length=${decoded.rgba.length} but '
      'width*height*4=$expectedLength (width=${decoded.width}, '
      'height=${decoded.height})',
    );
  }
  return DecodedRgba(
    rgba: decoded.rgba,
    width: decoded.width,
    height: decoded.height,
  );
}

/// A declared extent that would blow the decoded-pixel budget.
///
/// A NAMED type, not an anonymous StateError, because the sized-decode
/// fallback below has to tell a designed refusal apart from "the sized path
/// is broken" without sniffing an exception message across a boundary.
class ImageTooLargeException implements Exception {
  const ImageTooLargeException(this.message);

  final String message;

  @override
  String toString() => 'ImageTooLargeException: $message';
}

/// Refuses a declared extent that would blow the decoded-pixel budget.
///
/// Required on the SIZED path: the sidebar purpose returns `NO_THUMBNAIL` from
/// the loader before its budget check runs, so without this a 30000x30000 scan
/// would be decoded on the Dart heap and OOM the process. Kept on the full
/// path too because `PhotoExportService.exportBytesFor` invokes the decoder
/// directly. A null extent (unreadable IFD0) waves through, matching the
/// loader.
Future<void> _refuseOverBudget(String path) async {
  final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
  if (dims != null &&
      dims.width * dims.height * 4 > kDecodedPixelBudgetBytes) {
    throw ImageTooLargeException(
      'IMAGE_TOO_LARGE: TIFF extent ${dims.width}x${dims.height} exceeds the '
      'decoded-pixel budget of $kDecodedPixelBudgetBytes bytes',
    );
  }
}

/// [DngFullDecoder]-shaped TIFF arm. A missing/unreadable file throws
/// [FileSystemException] from `readAsBytes`, which downstream treats as the
/// same permanent miss as any other decoder throw.
Future<DecodedRgba> decodeTiffFull(
  String path, {
  TiffBytesDecoder decodeBytes = decodeTiffBytes,
}) async {
  await _refuseOverBudget(path);
  return decodeBytes(await File(path).readAsBytes());
}

/// [DngSizedDecoder]-shaped TIFF arm (sidebar thumbnails).
Future<DecodedRgba> decodeTiffSized(
  String path, {
  required int maxDim,
  TiffBytesDecoder decodeBytes = decodeTiffBytes,
}) async {
  await _refuseOverBudget(path);
  return decodeBytes(await File(path).readAsBytes(), maxDim: maxDim);
}

/// `isDecodablePath`, NOT `isRawPath`: the latter also matches D2 browse-only
/// containers (.cr2/.iiq/.mrw) the engine cannot decode, and routing one of
/// those to the engine arm would be a guaranteed-failing FFI round trip
/// instead of the immediate refusal the D2 ruling wants.
///
/// HEIC is checked FIRST and with its own predicate: `.heic` is also in
/// `bitmapDecodeExtensions`, so a plain `isBitmapDecodePath` test would send
/// it to `package:image`, which cannot read ISO-BMFF.
Future<DecodedRgba> dispatchFullDecode(
  String path, {
  DngFullDecoder rawArm = halcyonDngFullDecoder,
  DngFullDecoder tiffArm = decodeTiffFull,
  DngFullDecoder heifArm = halcyonHeifFullDecoder,
}) async {
  if (SupportedPhotoFormats.isHeifPath(path)) return heifArm(path);
  if (SupportedPhotoFormats.isBitmapDecodePath(path)) return tiffArm(path);
  if (SupportedPhotoFormats.isDecodablePath(path)) return rawArm(path);
  throw UnsupportedError('no full-decode route for $path');
}

// Process-wide, evidence-only: set ONLY when a sized decode threw and the
// full decode of the SAME file then succeeded. That conjunction is what makes
// it an indictment of the sized path rather than of the file -- a corrupt file
// fails both arms and must not poison every later thumbnail. Never re-armed:
// a capability that broke once in this process is not retried (invariant I8's
// motivation, image_preload_controller.dart:1027-1037).
//
// Fail-open: the default is "trusted". No Platform check anywhere (C-3) --
// the state flips on observed behaviour, never on which OS this is.
bool _sizedDecodeUntrusted = false;

@visibleForTesting
bool get debugSizedDecodeLatched => _sizedDecodeUntrusted;

/// Clears the process-wide latch. Tests only: a process-wide flag with no
/// reset leaks state between cases in one `flutter test` process.
@visibleForTesting
void debugResetSizedDecodeLatch() => _sizedDecodeUntrusted = false;

Future<DecodedRgba> _sizedArm(
  String path, {
  required int maxDim,
  required DngSizedDecoder rawArm,
  required DngSizedDecoder tiffArm,
  required DngSizedDecoder heifArm,
}) {
  if (SupportedPhotoFormats.isHeifPath(path)) {
    return heifArm(path, maxDim: maxDim);
  }
  if (SupportedPhotoFormats.isBitmapDecodePath(path)) {
    return tiffArm(path, maxDim: maxDim);
  }
  if (SupportedPhotoFormats.isDecodablePath(path)) {
    return rawArm(path, maxDim: maxDim);
  }
  throw UnsupportedError('no sized-decode route for $path');
}

/// Sized decode with a degrade-on-throw fallback to the full decode.
///
/// Guards the case the absence-only guard in ceyx structurally cannot cover
/// (`dng_decoder_service.dart:567-569` only checks whether the sized SYMBOL
/// exists): a symbol that is present and wrong. Only Halcyon's sidebar calls
/// with maxDim > 0, so only the sidebar can hit it -- which is exactly the
/// Windows symptom (root-cause R2.3.1 step 5).
///
/// At the DISPATCH level, covering all three arms: the failure shape is
/// arm-independent, and a RAW-only guard would be a guard written on the
/// motivating case instead of on the real precondition.
Future<DecodedRgba> dispatchSizedDecode(
  String path, {
  required int maxDim,
  DngSizedDecoder rawArm = halcyonDngSizedDecoder,
  DngSizedDecoder tiffArm = decodeTiffSized,
  DngSizedDecoder heifArm = halcyonHeifSizedDecoder,
  DngFullDecoder fullDecodeFallback = dispatchFullDecode,
}) async {
  if (_sizedDecodeUntrusted) return fullDecodeFallback(path);

  try {
    return await _sizedArm(
      path,
      maxDim: maxDim,
      rawArm: rawArm,
      tiffArm: tiffArm,
      heifArm: heifArm,
    );
  } on ImageTooLargeException {
    // A designed refusal, not a broken symbol: the full path would refuse
    // identically, and retrying it is how a 30000x30000 scan gets decoded.
    rethrow;
  } on UnsupportedError {
    // No route for this format at all -- the full dispatch answers the same.
    rethrow;
  } catch (e) {
    debugPrint(
      'sidebar.decode|stage=sized|err=${e.runtimeType}|'
      'msg=${e.toString().substring(0, e.toString().length.clamp(0, 200))}',
    );
    // Retry the SAME file on the full path first; only a SUCCESS here proves
    // the sized arm was at fault, and only then does the latch arm. If this
    // throws too, the exception propagates and the latch stays clear.
    final recovered = await fullDecodeFallback(path);
    _sizedDecodeUntrusted = true;
    debugPrint('sidebar.decode|stage=latched|msg=sized decode disabled for '
        'this process after a full-decode recovery');
    return recovered;
  }
}

/// The composition root's entry points. Plain `const` tear-offs, not closures:
/// the optional named arms are extra parameters, so each tear-off is still a
/// subtype of the seam typedef.
const DngFullDecoder halcyonFullDecoder = dispatchFullDecode;
const DngSizedDecoder halcyonSizedDecoder = dispatchSizedDecode;
