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
  // see `PhotoExportService._attachSourceExif` (M6 P3 review P-14
  // ruling). Handled in Dart by `photo_export_service.dart`'s
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

/// The file is a RAW container the engine can decode
/// (`SupportedPhotoFormats.isDecodablePath`) that carries no reachable
/// embedded full-size JPEG preview, so the caller must run a real RAW decode
/// (see `DngFullDecoder` in `dng_decode_contract.dart`). This is NOT a
/// failure. It was `.dng`-only until the 2026-08-26 RAW-coverage contract
/// generalised the route to every engine-decodable extension.
///
/// [exifOrientation] is the IFD0 Orientation tag value, in the range 1..8; it
/// is [kDefaultExifOrientation] when the tag is absent or unparseable. It is
/// read in Dart via `DngEmbeddedJpegExtractor.readOrientation`, a bounded
/// byte-range IFD0 walk that works on exactly this case -- a DNG with no
/// embedded preview; it returns null when the orientation could not be
/// determined, which is why this field falls back to
/// [kDefaultExifOrientation] rather than trusting a bare 1. The decoder does
/// not apply EXIF orientation, so Halcyon must.
/// [declaredPreviewsUnreadable] is the AD-022 "malformed" finding, carried
/// forward rather than acted on. It is true when the walker parsed the
/// container and found EVERY declared preview candidate unreadable. Until
/// 2026-08-26 that finding short-circuited into an immediate broken-file
/// failure inside the loader; the user overrode that pre-empt after measuring
/// a container whose previews are unreadable but whose sensor data decodes
/// fine in 383ms. Such a file now routes to the decoder like any other
/// preview-less RAW, and is reported broken ONLY if the decode also fails.
///
/// The flag exists so that post-decode verdict remains possible: the loader
/// knows the previews were unreadable but never decodes, while the layer that
/// owns the decoder seam (`photo_source.dart`) knows the decode outcome but
/// has not parsed the container. Neither can form the verdict alone. It
/// defaults to false so that "container declares no preview" — the ordinary
/// miss — stays the zero-configuration case, and so that every existing
/// construction site keeps compiling unchanged.
class NativeImageNeedsRawDecode extends NativeImageResult {
  const NativeImageNeedsRawDecode({
    required this.exifOrientation,
    this.declaredPreviewsUnreadable = false,
  });

  final int exifOrientation;

  /// True when the container declared preview candidates and all of them were
  /// unreadable (AD-022 `malformed`). Not a failure by itself — see the class
  /// doc; it only selects the failure code if the RAW decode ALSO fails.
  final bool declaredPreviewsUnreadable;
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

/// [NativeImageFailure.code] for contract decision D3: this build has no
/// native RAW decoder (iOS, Linux, web), so a RAW container that needs a real
/// decode cannot be rendered HERE — the file itself is fine and stays
/// browsable. It is deliberately NOT a fourth [NativeImageResult] variant
/// (AD-010/AD-011 freeze the sealed class at three), and deliberately NOT
/// conflated with `RAW_NO_EMBEDDED_PREVIEW`, which means "this container has
/// no preview and no decoder exists for its format anywhere".
///
/// `dartImageLoad` never emits this: it is free of `Platform` checks by
/// construction, so it reports [NativeImageNeedsRawDecode] and the layer that
/// owns the `DngFullDecoder` seam substitutes this code when no decoder is
/// available. Interface contract — do not rename.
const String kNoNativeDecoderCode = 'NO_NATIVE_DECODER';

/// The seam through which the image-bytes producer is called.
///
/// ONE definition for what used to be three structurally identical typedefs,
/// declared separately in app_state.dart, image_preload_controller.dart and
/// photo_source.dart; all three call sites now share this `NativeImageLoad`.
/// It lives here, in the file that imports nothing but `dart:typed_data`,
/// which is what resolves the import cycle `photo_source.dart` used to dodge
/// by re-declaring the type structurally.
typedef NativeImageLoad =
    Future<NativeImageResult> Function(
      String path, {
      required ImageRequestPurpose purpose,
    });
