import 'dart:io';
import 'dart:typed_data';

import 'package:exif/exif.dart' as pkg_exif;
import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../models/photo_item.dart';
import '../models/supported_photo_formats.dart';
import 'dart_image_loader.dart';
import 'dng_decode_contract.dart';
import 'exif_orientation.dart';
import 'image_source_types.dart';

/// Result of a "Thumbnail Starred" export batch. [failures] entries are
/// `"<filename>: <error message>"`, mirroring [RecycleOutcome]'s shape in
/// `photo_file_actions.dart`, and MUST be surfaced to the user — a silently
/// failed export looks identical to a broken app.
class ThumbnailExportOutcome {
  const ThumbnailExportOutcome({
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

class ThumbnailExportService {
  ThumbnailExportService({ExportBytesFetch? fetchBytes, DngFullDecoder? decoder})
    : _fetchBytes = fetchBytes ?? ((path) => exportBytesFor(path, decoder: decoder));

  final ExportBytesFetch _fetchBytes;

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
  }) async {
    final result =
        await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
    img.Image? frame;
    if (result is NativeImageBytes) {
      frame = img.decodeImage(result.bytes);
      // `image`'s own JPEG decoder already physically bakes EXIF orientation
      // into pixel layout at decode time and clears the Orientation tag
      // before this ever runs (verified against image-4.9.2's
      // bake_orientation.dart early-return path) -- this call is a no-op
      // safeguard for that case, and the real rotation for any other decoded
      // format that still carries an Orientation tag.
      if (frame != null) frame = img.bakeOrientation(frame);
    } else if (result is NativeImageNeedsRawDecode && decoder != null) {
      final decoded = await decoder(path);
      final wrapped = imageFromDecodedRgba(decoded);
      if (wrapped == null) return null;
      // FFI output is unrotated; bake from the signal's orientation.
      frame = bakeExifOnDecoded(wrapped, result.exifOrientation);
    }
    if (frame == null) return null;
    // Re-attach EXIF read from the ORIGINAL source file (M6 P3 review P-14
    // ruling): the decoded bytes above never carry it -- an embedded-preview
    // JPEG stream inside a DNG has no APP1 block of its own, and the FFI RAW
    // decode output is documented as carrying no EXIF at all. This mirrors
    // (core tags, not a byte-for-byte block copy) what the deleted native
    // export branch did by copying `CGImageSourceCopyPropertiesAtIndex` on
    // the source file. Orientation is always forced to 1: pixels are already
    // rotated above.
    await _attachSourceExif(frame, path);
    frame.exif.imageIfd['Orientation'] = 1;
    // img.copyResize does NOT propagate source.exif onto the resized output
    // (verified against image-4.9.2's copy_resize.dart -- it only reads
    // src.exif for its own orientation-aware sizing math), so the metadata
    // set above must be re-attached to the resized frame explicitly.
    final exif = frame.exif;
    if (frame.width > 2048 || frame.height > 2048) {
      frame = img.copyResize(
        frame,
        width: frame.width >= frame.height ? 2048 : null,
        height: frame.height > frame.width ? 2048 : null,
        interpolation: img.Interpolation.linear,
      );
      frame.exif = exif;
    }
    return Uint8List.fromList(img.encodeJpg(frame, quality: 90));
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

    final exif = frame.exif;
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
  /// [ThumbnailExportOutcome.failures] and does not abort the batch.
  /// [onProgress], if given, fires once per completed item with a
  /// monotonically increasing `done` count and the fixed `total`; because
  /// work is concurrent, completion order is not source order, so callers
  /// must report counts, not filenames.
  ///
  /// If [dest] does not exist, returns an empty outcome without throwing.
  Future<ThumbnailExportOutcome> exportStarred(
    List<PhotoItem> items,
    Directory dest, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (!await dest.exists()) {
      return const ThumbnailExportOutcome(exportedCount: 0, failures: []);
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
            '${p.basenameWithoutExtension(source.path)}.jpg',
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

    return ThumbnailExportOutcome(
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

/// Test seam for the RAW-decode half of [ThumbnailExportService.exportBytesFor]
/// -- the export path without needing a real file on disk.
@visibleForTesting
Future<Uint8List?> exportJpegForTest(
  DecodedRgba decoded, {
  int exifOrientation = 1,
}) async {
  final frame = imageFromDecodedRgba(decoded);
  if (frame == null) return null;
  return Uint8List.fromList(
    img.encodeJpg(bakeExifOnDecoded(frame, exifOrientation), quality: 90),
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
