import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart' show CeyxEncodeService, CeyxImageFormat;
import 'package:exif/exif.dart' as pkg_exif;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../models/photo_item.dart';
import '../../models/supported_photo_formats.dart';
import '../image_pipeline/dart_image_loader.dart';
import '../image_pipeline/dng_decode_contract.dart';
import '../image_pipeline/exif_orientation.dart';
import '../image_pipeline/image_source_types.dart';

/// Result of a "Thumbnail Starred" export batch. [failures] entries are
/// `"<filename>: <error message>"`, mirroring [RecycleOutcome]'s shape in
/// `photo_file_actions.dart`, and MUST be surfaced to the user — a silently
/// failed export looks identical to a broken app.
class PhotoExportOutcome {
  const PhotoExportOutcome({
    required this.exportedCount,
    required this.failures,
  });

  final int exportedCount;
  final List<String> failures;
}

/// Injection seam for fetching export-sized JPEG bytes for one source path.
/// The default implementation is decode -> resize -> encode in pure Dart
/// (M6 F-11, [exportBytesFor]); tests inject a fake so this service never
/// touches a real decode/encode pipeline.
typedef ExportBytesFetch = Future<Uint8List?> Function(String path);

/// Injection seam for the native encode step of [exportBytesFor]
/// (codec-expansion round, 2026-08-30). One seam for every non-JPEG format,
/// not one per format: `flutter test` cannot resolve the dylib outside a
/// built .app bundle (its dylib search path assumes ceyx's own repo
/// layout), so every format's test injects a pure-Dart fake and a
/// per-format typedef would multiply that boilerplate by six with no gain.
/// The default implementation is `CeyxEncodeService().encodeNative`.
typedef StillEncode = Future<Uint8List> Function(
  Uint8List rgba, {
  required CeyxImageFormat format,
  required int width,
  required int height,
  required int quality,
  required bool lossless,
  Uint8List? exif,
});

/// Default quality every JPEG export is encoded at, matching today's three
/// hardcoded literals (formerly `90` at every `img.encodeJpg` call site in
/// this file). Overridable per-app via [PhotoExportService.jpegQuality],
/// which the settings panel writes through (`AppState.setExportJpegQuality`).
const int kDefaultExportJpegQuality = 90;

/// Sentinel for [PhotoExportService.longEdge] / [ExportBytesFetch] callers:
/// "Original" -- re-encode at the source's own resolution, skipping the
/// resize step entirely. 0 is used because every real long-edge stop is a
/// positive pixel count, so it can never collide with a real target.
const int kOriginalExportLongEdge = 0;

/// Default long edge (px) an export is resized to before re-encoding, unless
/// the user picked [kOriginalExportLongEdge]. Matches the pre-existing
/// hardcoded `2048` this replaced (`ImageRequestPurpose.export.targetSize`
/// remains 2048 and is unrelated -- it sizes the PRE-resize decode/preview
/// fetch, not this service's own resize target).
const int kDefaultExportLongEdge = 2048;

/// The complete, ordered set of stops the "Export JPEG Size" slider offers.
/// [kOriginalExportLongEdge] (0) is deliberately last: it means "skip
/// resizing", not "the smallest stop".
const List<int> kExportLongEdgeStops = [
  480,
  720,
  1080,
  1440,
  kDefaultExportLongEdge,
  2560,
  3840,
  kOriginalExportLongEdge,
];

/// Human-readable label for one [kExportLongEdgeStops] entry, shared by the
/// settings panel's slider caption and the summary rail.
String exportLongEdgeLabel(int longEdge) =>
    longEdge == kOriginalExportLongEdge ? 'Original' : '${longEdge}px';

/// The output codec an export is encoded as (grown from two to six entries
/// in the 2026-08-30 codec-expansion round). [buildIntent] is a compile-time
/// "this app wants to offer the format" flag; the settings panel and
/// `AppState._normaliseExportFiletype` must NOT gate on it alone -- see
/// [buildIntent]'s own doc. Real selectability is
/// `AppState.selectableExportFiletypes` (build intent INTERSECTED with
/// runtime capability, ruling Q4).
enum ExportFiletype {
  jpeg(
    label: 'JPEG',
    extension: 'jpg',
    format: CeyxImageFormat.jpeg,
    buildIntent: true,
    usesQuality: true,
  ),
  heif(
    label: 'HEIF',
    extension: 'heic',
    format: CeyxImageFormat.heic,
    buildIntent: true,
    usesQuality: true,
  ),
  webpLossy(
    label: 'WebP (lossy)',
    extension: 'webp',
    format: CeyxImageFormat.webp,
    buildIntent: true,
    usesQuality: true,
  ),
  webpLossless(
    label: 'WebP (lossless)',
    extension: 'webp',
    format: CeyxImageFormat.webp,
    buildIntent: true,
    usesQuality: false,
    lossless: true,
  ),
  avif(
    label: 'AVIF',
    extension: 'avif',
    format: CeyxImageFormat.avif,
    buildIntent: true,
    usesQuality: true,
  ),
  jxl(
    label: 'JPEG XL',
    extension: 'jxl',
    format: CeyxImageFormat.jxl,
    buildIntent: true,
    usesQuality: true,
  );

  const ExportFiletype({
    required this.label,
    required this.extension,
    required this.format,
    required this.buildIntent,
    required this.usesQuality,
    this.lossless = false,
  });

  final String label;
  final String extension;

  /// The native format selector this entry encodes to.
  final CeyxImageFormat format;

  /// BUILD INTENT only -- "this app wants to offer the format". Real
  /// availability is build intent INTERSECTED with the runtime capability
  /// the native library reports (user ruling Q4, 2026-08-30). Never gate UI
  /// on this field alone: HEIF is absent on Android, WebP was absent on
  /// Windows before this round, and a const flag cannot know that --
  /// `AppState.selectableExportFiletypes` is the source of truth.
  final bool buildIntent;

  /// False for formats whose encoder ignores the quality knob (currently
  /// only [webpLossless]).
  final bool usesQuality;

  /// Requests mathematically lossless encoding.
  final bool lossless;
}

const ExportFiletype kDefaultExportFiletype = ExportFiletype.jpeg;

/// Default [StillEncode]: the real native call, off the caller's isolate
/// (matches [CeyxEncodeService]'s own off-UI-isolate contract).
Future<Uint8List> _defaultStillEncode(
  Uint8List rgba, {
  required CeyxImageFormat format,
  required int width,
  required int height,
  required int quality,
  required bool lossless,
  Uint8List? exif,
}) =>
    CeyxEncodeService().encodeNative(
      rgba,
      format: format,
      width: width,
      height: height,
      quality: quality,
      lossless: lossless,
      exif: exif,
    );

class PhotoExportService {
  PhotoExportService({
    ExportBytesFetch? fetchBytes,
    DngFullDecoder? decoder,
    StillEncode stillEncode = _defaultStillEncode,
  }) {
    _fetchBytes = fetchBytes ??
        ((path) => exportBytesFor(
              path,
              decoder: decoder,
              quality: jpegQuality,
              longEdge: longEdge,
              filetype: filetype,
              stillEncode: stillEncode,
            ));
  }

  late final ExportBytesFetch _fetchBytes;

  /// Quality of the JPEG the user EXPORTS. Set from the app-wide setting
  /// (`AppState.setExportJpegQuality`); read at call time, not at
  /// construction, because this service is built before prefs are hydrated.
  ///
  /// Unrelated to `kDisplayJpegQuality` (`jpeg_encoder.dart`), which governs
  /// display-only bytes that never reach disk.
  int jpegQuality = kDefaultExportJpegQuality;

  /// Long edge (px) the export is resized to, or [kOriginalExportLongEdge]
  /// to skip resizing. Set from the app-wide setting
  /// (`AppState.setExportLongEdge`); read at call time, same reasoning as
  /// [jpegQuality].
  int longEdge = kDefaultExportLongEdge;

  /// Output codec the export is encoded as. Set from the app-wide setting
  /// (`AppState.setExportFiletype`); read at call time, same reasoning as
  /// [jpegQuality]. What is actually encodable is
  /// `AppState.selectableExportFiletypes` -- see the enum doc.
  ExportFiletype filetype = kDefaultExportFiletype;

  /// Byte source = the same producer the detail view uses (P2.1). Purpose is
  /// PREVIEW deliberately: that branch returns full-size bytes OR the
  /// raw-decode signal for a no-preview DNG (the export purpose never emits
  /// the signal, P2.1 invariant); export sizing is this function's own job.
  ///
  /// Decode -> resize (long edge capped at 2048px, aspect ratio preserved) ->
  /// re-encode as JPEG q90 -- the Dart-side replacement for the deleted
  /// native export branch (`AppDelegate.swift`'s dedicated export path, which
  /// bypassed the JPEG/DNG raw-bytes passthroughs because those return
  /// original file bytes and would defeat the resize).
  static Future<Uint8List?> exportBytesFor(
    String path, {
    DngFullDecoder? decoder,
    int quality = kDefaultExportJpegQuality,
    int longEdge = kDefaultExportLongEdge,
    ExportFiletype filetype = kDefaultExportFiletype,
    StillEncode stillEncode = _defaultStillEncode,
  }) async {
    final result =
        await dartImageLoad(path, purpose: ImageRequestPurpose.preview);

    Uint8List? encodedSource;
    Uint8List? rgba;
    var rgbaWidth = 0;
    var rgbaHeight = 0;
    var orientation = kDefaultExifOrientation;

    if (result is NativeImageBytes) {
      encodedSource = result.bytes;
    } else if (result is NativeImageNeedsRawDecode && decoder != null) {
      final decoded = await decoder(path);
      if (decoded.rgba.length != decoded.width * decoded.height * 4) {
        return null;
      }
      rgba = decoded.rgba;
      rgbaWidth = decoded.width;
      rgbaHeight = decoded.height;
      orientation = result.exifOrientation;
    } else {
      return null;
    }

    final transform = exifTransformFor(orientation);
    // ImageRequestPurpose.export.targetSize (2048) sizes the PRE-resize
    // fetch/decode above via dartImageLoad; it is unrelated to this
    // service's own resize target, which is the user-settable [longEdge].
    final maxEdge = longEdge;

    // Everything below is pure CPU on `package:image`, so it runs on a worker
    // isolate (the pattern `exif_metadata_service.dart:63-70` already uses).
    // Only sendable values are captured: two nullable Uint8Lists, four ints
    // and a bool.
    final quarterTurnsCw = transform.quarterTurnsCw;
    final mirrored = transform.mirrored;

    if (filetype != ExportFiletype.jpeg) {
      // All non-JPEG formats share the decode/orient/resize step and then
      // hand raw RGBA to the native encoder with an EXIF block attached.
      // JPEG keeps its historical decode-mutate-re-encode path below,
      // unchanged.
      final resized = await Isolate.run<(Uint8List, int, int)?>(() {
        final frame = _decodeAndResizeFrame(
          encodedSource: encodedSource,
          rgba: rgba,
          rgbaWidth: rgbaWidth,
          rgbaHeight: rgbaHeight,
          quarterTurnsCw: quarterTurnsCw,
          mirrored: mirrored,
          maxEdge: maxEdge,
        );
        if (frame == null) return null;
        return (frame.getBytes(order: img.ChannelOrder.rgba), frame.width, frame.height);
      });
      if (resized == null) return null;
      final (rgbaBytes, width, height) = resized;

      // Orientation is forced to 1: the pixels above are already rotated, so
      // a carried-over Orientation tag would rotate them a second time.
      final exifBlock =
          await _readSourceExifBlock(path, forceOrientationOne: true);

      try {
        return await stillEncode(
          rgbaBytes,
          format: filetype.format,
          width: width,
          height: height,
          // A lossless format's encoder ignores quality; passing the user's
          // value would imply it does something.
          quality: filetype.usesQuality ? quality : 100,
          lossless: filetype.lossless,
          exif: exifBlock,
        );
      } catch (_) {
        // Native encode unavailable or failed -- reported like a null
        // decode: no file written, no crash. Unchanged from the round-2c
        // behaviour.
        return null;
      }
    }

    final jpeg = await Isolate.run<Uint8List?>(() {
      final frame = _decodeAndResizeFrame(
        encodedSource: encodedSource,
        rgba: rgba,
        rgbaWidth: rgbaWidth,
        rgbaHeight: rgbaHeight,
        quarterTurnsCw: quarterTurnsCw,
        mirrored: mirrored,
        maxEdge: maxEdge,
      );
      if (frame == null) return null;
      return Uint8List.fromList(img.encodeJpg(frame, quality: quality));
    });
    if (jpeg == null) return null;

    // EXIF is re-attached AFTER the isolate hop: `_attachSourceExif` reads
    // the ORIGINAL file with `package:exif` and mutates an img.Image, and an
    // img.Image is not sendable (M6 P3 review P-14 ruling: core tags, not a
    // byte-for-byte block copy, mirroring what the deleted native export
    // branch did by copying `CGImageSourceCopyPropertiesAtIndex` on the
    // source file). Decode the small (<=2048px) JPEG back, attach, re-encode.
    // Orientation is forced to 1: pixels are already rotated.
    final resized = img.decodeJpg(jpeg);
    if (resized == null) return jpeg;
    await _attachSourceExif(resized, path);
    resized.exif.imageIfd['Orientation'] = 1;
    return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
  }

  /// Shared decode -> orient -> resize step for both the JPEG and WebP
  /// export paths (extracted round-2b so the two isolate closures below stay
  /// in sync instead of hand-duplicating this logic). Only sendable
  /// arguments (nullable `Uint8List`s, ints, a bool) so it can run inside
  /// either `Isolate.run` closure unchanged.
  static img.Image? _decodeAndResizeFrame({
    required Uint8List? encodedSource,
    required Uint8List? rgba,
    required int rgbaWidth,
    required int rgbaHeight,
    required int quarterTurnsCw,
    required bool mirrored,
    required int maxEdge,
  }) {
    img.Image? frame;
    if (encodedSource != null) {
      frame = img.decodeImage(encodedSource);
      // `image`'s own JPEG decoder already physically bakes EXIF
      // orientation into pixel layout at decode time and clears the
      // Orientation tag before this ever runs (verified against
      // image-4.9.2's bake_orientation.dart early-return path) -- this
      // call is a no-op safeguard for that case, and the real rotation
      // for any other decoded format that still carries an Orientation
      // tag.
      if (frame != null) frame = img.bakeOrientation(frame);
    } else {
      frame = img.Image.fromBytes(
        width: rgbaWidth,
        height: rgbaHeight,
        bytes: rgba!.buffer,
        bytesOffset: rgba.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      // FFI output is unrotated; bake from the signal's orientation.
      if (quarterTurnsCw != 0) {
        frame = img.copyRotate(frame, angle: quarterTurnsCw * 90);
      }
      if (mirrored) frame = img.flipHorizontal(frame);
    }
    if (frame == null) return null;
    if (maxEdge != kOriginalExportLongEdge &&
        (frame.width > maxEdge || frame.height > maxEdge)) {
      frame = img.copyResize(
        frame,
        width: frame.width >= frame.height ? maxEdge : null,
        height: frame.height > frame.width ? maxEdge : null,
        interpolation: img.Interpolation.linear,
      );
    }
    return frame;
  }

  /// Reads EXIF from [sourcePath] via `package:exif` (the same reader
  /// `ExifMetadataService` uses as the sole, all-platforms path post-F-14 --
  /// proven to parse DNG/TIFF-structured files, not just JPEG) and copies a
  /// core set of tags onto [frame]'s [img.ExifData]. This is a best-effort
  /// re-read of the source file, not a full block copy: maker notes and any
  /// tag outside this list are not carried over. Failures (unreadable file,
  /// unsupported format, no EXIF present) are swallowed -- a missing source
  /// EXIF block must not fail the export.
  static Future<void> _attachSourceExif(img.Image frame, String sourcePath) async {
    Map<String, pkg_exif.IfdTag> tags;
    try {
      tags = await pkg_exif.readExifFromFile(File(sourcePath));
    } catch (_) {
      return;
    }
    if (tags.isEmpty) return;
    _applyCoreExifTags(frame.exif, tags);
  }

  /// The core tag set carried over from a source file's EXIF into an export,
  /// shared by [_attachSourceExif] (JPEG, mutates an `img.Image`) and
  /// [_readSourceExifBlock] (every other format, emits a raw byte block).
  /// Two divergent tag sets would mean a JPEG export and a WebP export of
  /// the same photo disagree about its own metadata.
  static void _applyCoreExifTags(
    img.ExifData exif,
    Map<String, pkg_exif.IfdTag> tags,
  ) {
    final imageIfd = exif.imageIfd;
    final exifIfd = exif.exifIfd;
    final gpsIfd = exif.gpsIfd;

    String? ascii(String key) {
      final tag = tags[key];
      if (tag == null) return null;
      final value = tag.printable.trim();
      return value.isEmpty ? null : value;
    }

    void setAscii(img.IfdDirectory dir, String tagName, String sourceKey) {
      final value = ascii(sourceKey);
      if (value != null) dir[tagName] = value;
    }

    void setRational(img.IfdDirectory dir, String tagName, String sourceKey) {
      final values = tags[sourceKey]?.values;
      if (values is pkg_exif.IfdRatios && values.ratios.isNotEmpty) {
        final r = values.ratios.first;
        dir[tagName] = [r.numerator, r.denominator];
      }
    }

    void setRationalList(
      img.IfdDirectory dir,
      String tagName,
      String sourceKey,
    ) {
      final values = tags[sourceKey]?.values;
      if (values is pkg_exif.IfdRatios && values.ratios.isNotEmpty) {
        dir[tagName] = values.ratios
            .map((r) => [r.numerator, r.denominator])
            .toList();
      }
    }

    setAscii(imageIfd, 'Make', 'Image Make');
    setAscii(imageIfd, 'Model', 'Image Model');
    setAscii(imageIfd, 'DateTime', 'Image DateTime');
    setAscii(imageIfd, 'Artist', 'Image Artist');

    setAscii(exifIfd, 'DateTimeOriginal', 'EXIF DateTimeOriginal');
    setRational(exifIfd, 'ExposureTime', 'EXIF ExposureTime');
    setRational(exifIfd, 'FNumber', 'EXIF FNumber');
    setRational(exifIfd, 'FocalLength', 'EXIF FocalLength');
    setAscii(exifIfd, 'LensModel', 'EXIF LensModel');
    final iso = tags['EXIF ISOSpeedRatings']?.values.firstAsInt();
    if (iso != null && iso > 0) exifIfd['ISOSpeed'] = iso;

    setAscii(gpsIfd, 'GPSLatitudeRef', 'GPS GPSLatitudeRef');
    setRationalList(gpsIfd, 'GPSLatitude', 'GPS GPSLatitude');
    setAscii(gpsIfd, 'GPSLongitudeRef', 'GPS GPSLongitudeRef');
    setRationalList(gpsIfd, 'GPSLongitude', 'GPS GPSLongitude');
  }

  /// Reads the source file's EXIF with `package:exif` -- the same reader
  /// [_attachSourceExif] uses -- and serialises the shared core tag set
  /// ([_applyCoreExifTags]) as a raw big-endian TIFF/EXIF block, which is
  /// exactly what `CeyxEncodeMetadata.exif` expects (no APP1 marker, no JXL
  /// offset prefix; each container's writer adds its own wrapper).
  ///
  /// Returns null when the source has no EXIF: a missing block must not
  /// fail an export, matching the swallow-and-continue behaviour
  /// [_attachSourceExif] has always had.
  static Future<Uint8List?> _readSourceExifBlock(
    String sourcePath, {
    required bool forceOrientationOne,
  }) async {
    Map<String, pkg_exif.IfdTag> tags;
    try {
      tags = await pkg_exif.readExifFromFile(File(sourcePath));
    } catch (_) {
      return null;
    }
    if (tags.isEmpty) return null;

    final exif = img.ExifData();
    _applyCoreExifTags(exif, tags);
    if (forceOrientationOne) {
      exif.imageIfd['Orientation'] = 1;
    }
    if (exif.isEmpty) return null;

    final out = img.OutputBuffer();
    exif.write(out);
    return out.getBytes();
  }

  // ponytail: concurrency ceiling of 4 — a RAW full decode can cost hundreds
  // of MB in flight, so letting every starred item decode at once risks OOM
  // on large batches. Each in-flight worker now runs its own decode/resize/
  // encode in this isolate rather than dispatching to a native queue; the
  // ceiling still bounds how many full-size RAW decodes are live at once.
  static const int _maxConcurrent = 4;

  /// Exports every starred item in [items] as a `<=2048px`-long-edge JPEG
  /// into [dest], one file per item named `<basenameWithoutExtension>.jpg`,
  /// overwriting any existing file at that path.
  ///
  /// A failure fetching or writing one item is recorded in
  /// [PhotoExportOutcome.failures] and does not abort the batch.
  /// [onProgress], if given, fires once per completed item with a
  /// monotonically increasing `done` count and the fixed `total`; because
  /// work is concurrent, completion order is not source order, so callers
  /// must report counts, not filenames.
  ///
  /// If [dest] does not exist, returns an empty outcome without throwing.
  Future<PhotoExportOutcome> exportStarred(
    List<PhotoItem> items,
    Directory dest, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (!await dest.exists()) {
      return const PhotoExportOutcome(exportedCount: 0, failures: []);
    }

    final starredItems = items
        .where((item) => item.status == PhotoStatus.starred)
        .toList();

    final total = starredItems.length;
    var done = 0;
    var exportedCount = 0;
    final failures = <String>[];
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= starredItems.length) return;
        nextIndex++;
        final item = starredItems[index];
        final source = SupportedPhotoFormats.bestFileToLoad(item.files);
        final label = source != null ? p.basename(source.path) : item.id;
        try {
          if (source == null) {
            throw StateError('No source file for this item');
          }
          final bytes = await _fetchBytes(source.path);
          if (bytes == null) {
            throw StateError('Export produced no image data');
          }
          final outPath = p.join(
            dest.path,
            '${p.basenameWithoutExtension(source.path)}.${filetype.extension}',
          );
          await File(outPath).writeAsBytes(bytes);
          exportedCount++;
        } catch (e) {
          failures.add('$label: $e');
        } finally {
          done++;
          onProgress?.call(done, total);
        }
      }
    }

    final workerCount = total < _maxConcurrent ? total : _maxConcurrent;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    return PhotoExportOutcome(
      exportedCount: exportedCount,
      failures: failures,
    );
  }
}

/// Wraps a raw RGBA8 frame from the FFI decoder as an [img.Image].
///
/// `bytesOffset` and `order` are NOT optional decoration: `decoded.rgba` can
/// be a VIEW into a larger buffer (non-zero `offsetInBytes`), and
/// `img.Image.fromBytes` reads from the START of the ByteBuffer unless told
/// otherwise -- so omitting them silently reads the wrong bytes with the
/// wrong channel order. The correct shape is the one
/// `sidebar_thumbnail_codec.dart:_encodeJpeg` already uses.
///
/// Returns null when the buffer and the dimensions disagree, rather than
/// constructing a mis-sized image whose pixels are meaningless.
img.Image? imageFromDecodedRgba(DecodedRgba decoded) {
  final expected = decoded.width * decoded.height * 4;
  if (decoded.rgba.length != expected) return null;
  return img.Image.fromBytes(
    width: decoded.width,
    height: decoded.height,
    bytes: decoded.rgba.buffer,
    bytesOffset: decoded.rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
}

/// Test seam for the RAW-decode half of [PhotoExportService.exportBytesFor]
/// -- the export path without needing a real file on disk.
@visibleForTesting
Future<Uint8List?> exportJpegForTest(
  DecodedRgba decoded, {
  int exifOrientation = 1,
  int quality = kDefaultExportJpegQuality,
}) async {
  final frame = imageFromDecodedRgba(decoded);
  if (frame == null) return null;
  return Uint8List.fromList(
    img.encodeJpg(bakeExifOnDecoded(frame, exifOrientation), quality: quality),
  );
}

/// Applies an EXIF Orientation value (1..8) to a raw-decoded (unrotated)
/// [img.Image] the way [img.bakeOrientation] does for images that already
/// carry Orientation in their own EXIF block. `dng_processor`'s FFI decode
/// output carries no EXIF, so this applies the shared table by hand against
/// the signal's own orientation (M6 F-11).
///
/// The 8-case mapping itself lives in `exif_orientation.dart` -- this function
/// only translates it into `package:image` operations.
img.Image bakeExifOnDecoded(img.Image image, int exifOrientation) {
  final transform = exifTransformFor(exifOrientation);
  var out = image;
  if (transform.quarterTurnsCw != 0) {
    out = img.copyRotate(out, angle: transform.quarterTurnsCw * 90);
  }
  if (transform.mirrored) {
    out = img.flipHorizontal(out);
  }
  return out;
}
