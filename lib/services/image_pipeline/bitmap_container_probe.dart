import 'package:ceyx/ceyx.dart';

import '../../models/supported_photo_formats.dart';
import 'dng_embedded_jpeg_extractor.dart';
import 'image_source_types.dart';

/// Extent and orientation of an already-rendered bitmap container, read from
/// metadata only — never by decoding.
typedef BitmapContainerExtent = ({int width, int height, int orientation});

/// The loader's view of the probe: path in, extent out, never throws.
typedef BitmapContainerProbe = Future<BitmapContainerExtent?> Function(
  String path,
);

/// Injection seam for the native HEIF metadata probe, so tests can exercise
/// every branch without loading a dylib.
typedef HeifExtentProbe = Future<BitmapContainerExtent?> Function(String path);

/// Reads a HEIC's primary-item extent through the `ceyx` FFI surface.
///
/// Never throws and never reports a partial answer: an absent library, an
/// absent symbol, or a native error all become `null`. This is the layer that
/// owns the "is there a decoder on this platform" question (contract C-3), so
/// that `dart_image_loader.dart` can stay free of `Platform` checks.
Future<BitmapContainerExtent?> heifExtentProbe(String path) async {
  try {
    final probe = await HeifDecoderService().probeOnWorker(path);
    if (probe == null) return null;
    return (
      width: probe.width,
      height: probe.height,
      orientation: probe.orientation,
    );
  } catch (_) {
    return null;
  }
}

/// One question — "how big is this container and which way up is it?" — with
/// one answer per container family:
///
///   .heic/.heif -> the native libheif probe (ISO-BMFF; the IFD0 walker
///                  returns null on it, which would silently mean
///                  "unknown extent, orientation 1")
///   everything  -> `DngEmbeddedJpegExtractor`'s bounded IFD0 walk, which is
///                  what TIFF and every TIFF-structured RAW already used
///
/// Returning `null` means "unknown", and callers must treat it as permission
/// to continue, not as a failure: that is exactly how the loader has always
/// treated an unreadable IFD0.
Future<BitmapContainerExtent?> probeBitmapContainer(
  String path, {
  HeifExtentProbe heifProbe = heifExtentProbe,
}) async {
  try {
    if (SupportedPhotoFormats.isHeifPath(path)) {
      // Awaited inside the try so a throwing probe (an injected fake, or a
      // future ceyx change) is swallowed to null rather than escaping — the
      // loader above is documented as never throwing.
      return await heifProbe(path);
    }
    final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
    if (dims == null) return null;
    final orientation = await DngEmbeddedJpegExtractor.readOrientation(path);
    return (
      width: dims.width,
      height: dims.height,
      orientation: orientation ?? kDefaultExifOrientation,
    );
  } catch (_) {
    // The loader above this is documented as never throwing, and the sidebar
    // path below it treats a bad orientation as cosmetic. Swallowing here
    // keeps both promises with one catch instead of three.
    return null;
  }
}

/// Orientation alone, for callers that already know the extent is fine — the
/// sidebar's sized-decode path. Falls back to [kDefaultExifOrientation] when
/// nothing can answer, which is the identity transform.
Future<int> bitmapContainerOrientation(
  String path, {
  HeifExtentProbe heifProbe = heifExtentProbe,
}) async {
  final extent = await probeBitmapContainer(path, heifProbe: heifProbe);
  return extent?.orientation ?? kDefaultExifOrientation;
}
