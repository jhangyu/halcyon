import 'dart:typed_data';

/// Pure types for the `NativeImageLoad` seam (`photo_source.dart:76-80`).
///
/// M6 P3.3: split out of `native_thumbnail_service.dart` when its native
/// thumbnail `MethodChannel` service was deleted. These types have
/// no platform dependency (no `flutter/services` import) -- they describe the
/// SHAPE of an image-bytes request outcome, not how it was produced. The
/// production implementation of the seam is `dartImageLoad`
/// (`dart_image_loader.dart`); this file exists so both the production
/// producer and every test fake can share one vocabulary without importing a
/// channel-backed service that no longer exists.
enum ImageRequestPurpose {
  sidebarThumbnail(targetSize: 200, platformValue: 'sidebarThumbnail'),
  // 2800px approximates a typical retina window long edge x2; if a real
  // window-size channel becomes available (AppState-driven, out of this
  // file's ownership), this static default can be replaced with a
  // per-request value without changing the loader's argument shape.
  preview(targetSize: 2800, platformValue: 'preview'),
  // Social-media export: long edge capped at 2048px, aspect ratio preserved,
  // core EXIF (Make/Model/DateTime[Original]/Artist/ExposureTime/FNumber/
  // FocalLength/ISO/LensModel/GPS lat-long) re-read from the ORIGINAL source
  // file and carried over, with Orientation forced to 1 (pixels are already
  // rotated). This is a best-effort re-read of a fixed tag set, not a
  // byte-for-byte copy of the source's full EXIF block (no maker notes) --
  // see `ThumbnailExportService._attachSourceExif` (M6 P3 review P-14
  // ruling). Handled in Dart by `thumbnail_export_service.dart`'s
  // `exportBytesFor` (M6 F-11): decode -> resize -> encode, replacing the
  // native export branch AppDelegate.swift used to run.
  export(targetSize: 2048, platformValue: 'export');

  const ImageRequestPurpose({
    required this.targetSize,
    required this.platformValue,
  });

  final int targetSize;
  final String platformValue;
}

/// Outcome of an image-bytes request through the `NativeImageLoad` seam.
///
/// ROUND-3B FROZEN INTEGRATION TYPE (pipe squad). Written by the squad lead
/// before implementation started so the native-signal half and the decode/
/// display half program against the same shape without negotiating it
/// mid-flight. Exactly three variants; do not add a fourth without the
/// squad lead's sign-off.
sealed class NativeImageResult {
  const NativeImageResult();
}

/// The loader returned encoded image bytes (JPEG/PNG, or an embedded
/// preview). The pre-existing happy path; replaces the old non-null
/// `Uint8List` return.
class NativeImageBytes extends NativeImageResult {
  const NativeImageBytes(this.bytes);

  final Uint8List bytes;
}

/// The file is a DNG that carries no embedded full-size JPEG preview, so the
/// caller must run a real RAW decode (see `DngFullDecoder` in
/// `dng_decode_contract.dart`). This is NOT a failure.
///
/// [exifOrientation] is the IFD0 Orientation tag value, in the range 1..8; it
/// is [kDefaultExifOrientation] when the tag is absent or unparseable. It is
/// read in Dart via `DngPreviewExtractor.readOrientation`, a bounded
/// byte-range IFD0 walk that works on exactly this case -- a DNG with no
/// embedded preview; it returns null when the orientation could not be
/// determined, which is why this field falls back to
/// [kDefaultExifOrientation] rather than trusting a bare 1. The decoder does
/// not apply EXIF orientation, so Halcyon must.
class NativeImageNeedsRawDecode extends NativeImageResult {
  const NativeImageNeedsRawDecode({required this.exifOrientation});

  final int exifOrientation;
}

/// A genuine failure (unreadable file, decode failure, unsupported format).
/// Replaces the old `null` return; callers must treat this, and only this,
/// as "no image available".
class NativeImageFailure extends NativeImageResult {
  const NativeImageFailure(this.code, this.message);

  final String code;
  final String? message;
}

/// EXIF Orientation value meaning "no transform"; also the fallback used when
/// the tag is missing or outside the 1..8 range.
const int kDefaultExifOrientation = 1;
