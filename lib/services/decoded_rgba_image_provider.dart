import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'dng_decode_contract.dart';
import 'photo_payload.dart';

/// Turns a [DecodedRgba] (RGBA8 straight from the native DNG decoder) into a
/// display-ready [ui.Image], applying EXIF orientation.
///
/// The decoder deliberately does NOT read or apply EXIF Orientation (see the
/// round-3b handover §6), so it has to happen here or every portrait phone
/// DNG shows up sideways.
///
/// Ownership: the returned [ui.Image] belongs to the CALLER, which must
/// [ui.Image.dispose] it. At 4080x3056 RGBA8 that handle is ~50MB, so
/// dropping it on the floor is a leak, not a nit. The intermediate
/// unoriented image is owned by this function and disposed here.
Future<ui.Image> decodedRgbaToImage(
  DecodedRgba rgba, {
  required int exifOrientation,
}) async {
  final raw = await _imageFromPixels(rgba);
  late final ui.Image oriented;
  try {
    oriented = await applyExifOrientation(raw, exifOrientation);
  } catch (_) {
    raw.dispose();
    rethrow;
  }
  // applyExifOrientation never disposes, and returns `src` itself for the
  // identity case -- so only dispose the intermediate when it really is a
  // separate image.
  if (!identical(oriented, raw)) raw.dispose();
  return oriented;
}

/// Applies EXIF [orientation] (1..8) to [src].
///
/// **The caller owns both images**: this function never disposes anything,
/// including [src]. For orientation 1 (and for any unrecognised value -- an
/// unknown orientation tag is not a reason to refuse to show the photo) it
/// returns [src] ITSELF, so callers must use [identical] before disposing an
/// intermediate.
Future<ui.Image> applyExifOrientation(ui.Image src, int orientation) async {
  final transform = _ExifTransform.forOrientation(orientation);
  if (transform.isIdentity) return src;
  // ponytail: re-render through the GPU rather than permuting the 50MB byte
  // buffer on the Dart heap. Costs one transient extra ui.Image; a Dart-side
  // rotate would allocate the same 50MB AND be slower.
  return _applyTransform(src, transform);
}

Future<ui.Image> _imageFromPixels(DecodedRgba decoded) {
  final expected = decoded.width * decoded.height * 4;
  if (decoded.rgba.length != expected) {
    // A length mismatch means the buffer and the dimensions disagree; letting
    // it through reads out of bounds in the engine.
    throw ArgumentError(
      'DecodedRgba buffer is ${decoded.rgba.length} bytes but '
      '${decoded.width}x${decoded.height} RGBA8 needs $expected',
    );
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    decoded.rgba,
    decoded.width,
    decoded.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Reduces a freshly decoded RAW frame to window-resolution RGBA pixels,
/// applying EXIF [exifOrientation] and the downscale to [longEdge] in the SAME
/// GPU pass, and disposes every intermediate.
///
/// This is `PhotoSource` step 3, and it is what makes RAW items affordable to
/// retain (design §3.1/§3.2). The decoder hands back a full-resolution frame --
/// 4080x3056 RGBA8 is ~50MB, and the FFI call that produced it cost 61-406ms --
/// which is far too expensive to keep nine of. What survives this function is
/// the window-resolution buffer only (at 2800px long edge, ~14MB), from which
/// the displayed image rebuilds in a memcpy plus a GPU upload.
///
/// Nothing is left owned by the caller: both `ui.Image` intermediates are
/// disposed here and the result is a plain [Uint8List].
Future<PixelPayload> decodedRgbaToPixelPayload(
  DecodedRgba decoded, {
  required int exifOrientation,
  required int longEdge,
}) async {
  final raw = await _imageFromPixels(decoded);
  ui.Image? scaled;
  try {
    final transform = _ExifTransform.forOrientation(exifOrientation);
    final swap = transform.quarterTurnsCw.isOdd;
    final orientedLongEdge = swap
        ? math.max(raw.height, raw.width)
        : math.max(raw.width, raw.height);
    // Never upscale: a preview smaller than the window stays its own size, so
    // a small embedded frame does not get inflated into a bigger buffer than
    // the pixels justify.
    final scale = longEdge <= 0 || orientedLongEdge <= longEdge
        ? 1.0
        : longEdge / orientedLongEdge;

    final source = transform.isIdentity && scale == 1.0
        ? raw
        : (scaled = await _applyTransform(raw, transform, scale));

    // ponytail: rawRgba is PREMULTIPLIED where the decoder's input was
    // straight RGBA. The two agree exactly for opaque pixels, which is every
    // pixel a RAW decode produces. Revisit only if a decoder starts emitting
    // alpha.
    final data = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('could not read back the scaled RAW frame');
    }
    return PixelPayload(
      rgba: data.buffer.asUint8List(),
      width: source.width,
      height: source.height,
    );
  } finally {
    scaled?.dispose();
    raw.dispose();
  }
}

Future<ui.Image> _applyTransform(
  ui.Image src,
  _ExifTransform t, [
  double scale = 1.0,
]) async {
  final swap = t.quarterTurnsCw.isOdd;
  final orientedWidth = swap ? src.height : src.width;
  final orientedHeight = swap ? src.width : src.height;
  final outWidth = math.max(1, (orientedWidth * scale).round());
  final outHeight = math.max(1, (orientedHeight * scale).round());

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Applied first so the orientation maths below can stay in source-pixel
  // units: one pass, one resample.
  if (scale != 1.0) canvas.scale(scale);
  if (t.mirrored) {
    // Source-pixel units, because canvas.scale above already established
    // them -- using the scaled output width here would mirror about the wrong
    // axis and silently crop.
    canvas.translate(orientedWidth.toDouble(), 0);
    canvas.scale(-1, 1);
  }
  switch (t.quarterTurnsCw) {
    case 1:
      canvas.translate(src.height.toDouble(), 0);
      canvas.rotate(math.pi / 2);
    case 2:
      canvas.translate(src.width.toDouble(), src.height.toDouble());
      canvas.rotate(math.pi);
    case 3:
      canvas.translate(0, src.width.toDouble());
      canvas.rotate(-math.pi / 2);
  }
  canvas.drawImage(
    src,
    Offset.zero,
    Paint()
      // Pure rotation/mirroring is an exact multiple of 90 degrees, so
      // filtering it can only blur. A DOWNSCALE is the opposite case: nearest
      // neighbour at 0.3x drops most of the pixels and aliases badly.
      ..filterQuality = scale == 1.0
          ? FilterQuality.none
          : FilterQuality.medium
      ..isAntiAlias = false,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(outWidth, outHeight);
  } finally {
    picture.dispose();
  }
}

/// EXIF Orientation decomposed into "mirror horizontally, then rotate N
/// quarter-turns clockwise". Both steps are exact multiples of 90 degrees, so
/// the re-render is pixel-exact with filtering off.
@immutable
class _ExifTransform {
  const _ExifTransform(this.quarterTurnsCw, this.mirrored);

  final int quarterTurnsCw;
  final bool mirrored;

  bool get isIdentity => quarterTurnsCw == 0 && !mirrored;

  static _ExifTransform forOrientation(int orientation) {
    return switch (orientation) {
      2 => const _ExifTransform(0, true), // mirror horizontal
      3 => const _ExifTransform(2, false), // rotate 180
      4 => const _ExifTransform(2, true), // mirror vertical
      5 => const _ExifTransform(1, true), // transpose
      6 => const _ExifTransform(1, false), // rotate 90 CW
      7 => const _ExifTransform(3, true), // transverse
      8 => const _ExifTransform(3, false), // rotate 270 CW
      _ => const _ExifTransform(0, false), // 1, and anything unrecognised
    };
  }
}
