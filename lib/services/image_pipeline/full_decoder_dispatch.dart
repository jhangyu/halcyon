import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../models/supported_photo_formats.dart';
import 'dng_decode_contract.dart';
import 'dng_decode_service.dart';
import 'dng_embedded_jpeg_extractor.dart';
import 'heif_decode_service.dart';
import 'jxl_decode_service.dart';

/// One production implementation of [DngFullDecoder] for every format Halcyon
/// can turn into RGBA, so that `dart_image_loader.dart` and `photo_source.dart`
/// need no format knowledge beyond the registry
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
/// not a guarantee — callers read the returned dimensions back.
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
/// A NAMED type, not an anonymous StateError: `_refuseOverBudget` throws it
/// before any decode is attempted, and the tests tell that designed refusal
/// apart from a decoder that merely failed. (It used to also be what let the
/// sized-decode fallback distinguish a refusal from a broken symbol; that layer
/// was retired 2026-09-03 — see the AD entry retiring AD-039 decision (2).)
class ImageTooLargeException implements Exception {
  const ImageTooLargeException(this.message);

  final String message;

  @override
  String toString() => 'ImageTooLargeException: $message';
}

/// Refuses a declared extent that would blow the decoded-pixel budget.
///
/// `PhotoExportService.exportBytesFor` invokes the decoder directly, so the
/// loader's own budget check is not on every path into a TIFF decode; this is.
/// A null extent (unreadable IFD0) waves through, matching the loader.
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
  DngFullDecoder jxlArm = halcyonJxlFullDecoder,
}) async {
  // isLibheifPath, NOT isHeifPath: .avif is AV1 in the same container and goes
  // through the same libheif entry point. Checked FIRST, and with its own
  // predicate, because all three extensions are also in
  // bitmapDecodeExtensions, and a plain isBitmapDecodePath test would send
  // them to package:image, which cannot read ISO-BMFF.
  if (SupportedPhotoFormats.isLibheifPath(path)) return heifArm(path);
  if (SupportedPhotoFormats.isJxlPath(path)) return jxlArm(path);
  if (SupportedPhotoFormats.isBitmapDecodePath(path)) return tiffArm(path);
  if (SupportedPhotoFormats.isDecodablePath(path)) return rawArm(path);
  throw UnsupportedError('no full-decode route for $path');
}

/// The composition root's entry point. A plain `const` tear-off, not a
/// closure: the optional named arms are extra parameters, so the tear-off is
/// still a subtype of the seam typedef.
const DngFullDecoder halcyonFullDecoder = dispatchFullDecode;
