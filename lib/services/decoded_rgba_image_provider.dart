import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'dng_decode_contract.dart';

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

Future<ui.Image> _applyTransform(ui.Image src, _ExifTransform t) async {
  final swap = t.quarterTurnsCw.isOdd;
  final outWidth = swap ? src.height : src.width;
  final outHeight = swap ? src.width : src.height;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (t.mirrored) {
    canvas.translate(outWidth.toDouble(), 0);
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
      ..filterQuality = FilterQuality.none
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

/// An [ImageProvider] backed by an already-decoded [ui.Image].
///
/// Exists because the tier-2 full-size path for decoder-sourced DNGs has
/// pixels, not encoded bytes, so [MemoryImage] cannot be used — while the
/// display side ([main_detail_view.dart]) needs a genuine [ImageProvider]:
/// it calls `provider.resolve(...)` directly for perf instrumentation and
/// relies on `Image(gaplessPlayback: true)` for the seamless tier-1 -> tier-2
/// swap, both of which are [ImageStream] mechanics.
///
/// **Ownership contract (the reason this class exists rather than a bare
/// `OneFrameImageStreamCompleter`)**: [image] stays owned by whoever created
/// it (the preload controller). Every [ImageInfo] this provider hands to the
/// framework carries a `clone()` instead, because [ImageCache] disposes the
/// [ImageInfo] it evicts. Without the clone, an eviction would dispose the
/// controller's master handle out from under it and the next resolve would
/// paint a disposed image; with it, eviction only drops one handle and the
/// underlying pixels survive until the controller disposes the master too.
@immutable
class DecodedRgbaImageProvider extends ImageProvider<DecodedRgbaImageProvider> {
  const DecodedRgbaImageProvider(this.image, {this.scale = 1.0});

  /// The master handle. Not disposed by this provider.
  final ui.Image image;
  final double scale;

  @override
  Future<DecodedRgbaImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<DecodedRgbaImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    DecodedRgbaImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(
        ImageInfo(image: key.image.clone(), scale: key.scale),
      ),
    );
  }

  // Identity on the ui.Image, not value equality: two providers are the same
  // ImageCache entry exactly when they wrap the same decoded image. A new
  // decode for the same photo produces a new ui.Image and therefore a new
  // key, which is what makes stale entries evictable by identity.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DecodedRgbaImageProvider &&
        identical(other.image, image) &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(identityHashCode(image), scale);

  @override
  String toString() =>
      'DecodedRgbaImageProvider(${image.width}x${image.height}, scale: $scale)';
}
