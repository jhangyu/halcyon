import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models/photo_item.dart';
import '../models/supported_photo_formats.dart';
import 'dart_image_loader.dart';
import 'dng_decode_contract.dart';
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
      // Pixels rotated per EXIF, Orientation forced to 1 -- the export
      // contract documented on ImageRequestPurpose.export
      // (image_source_types.dart).
      if (frame != null) frame = img.bakeOrientation(frame);
    } else if (result is NativeImageNeedsRawDecode && decoder != null) {
      final decoded = await decoder(path);
      frame = img.Image.fromBytes(
        width: decoded.width,
        height: decoded.height,
        bytes: decoded.rgba.buffer,
        numChannels: 4,
      );
      // FFI output is unrotated; bake from the signal's orientation.
      frame = bakeExifOnDecoded(frame, result.exifOrientation);
    }
    if (frame == null) return null;
    if (frame.width > 2048 || frame.height > 2048) {
      frame = img.copyResize(
        frame,
        width: frame.width >= frame.height ? 2048 : null,
        height: frame.height > frame.width ? 2048 : null,
        interpolation: img.Interpolation.linear,
      );
    }
    return Uint8List.fromList(img.encodeJpg(frame, quality: 90));
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

/// Applies an EXIF Orientation value (1..8) to a raw-decoded (unrotated)
/// [image.Image] the way [img.bakeOrientation] does for images that already
/// carry Orientation in their own EXIF block. `dng_processor`'s FFI decode
/// output carries no EXIF, so this reimplements the 8-case mapping by hand
/// against the signal's own [exifOrientation] (M6 F-11, `dartImageLoad`'s
/// [NativeImageNeedsRawDecode]).
///
/// EXIF Orientation semantics (all 8 cases spelled out -- do not special-case
/// only the common values):
///  1 = normal (identity)
///  2 = flip horizontal
///  3 = rotate 180
///  4 = flip vertical
///  5 = rotate 90 CW, then flip horizontal (transpose)
///  6 = rotate 90 CW
///  7 = rotate 270 CW, then flip horizontal (transverse)
///  8 = rotate 270 CW
img.Image bakeExifOnDecoded(img.Image image, int exifOrientation) {
  switch (exifOrientation) {
    case 1:
      return image;
    case 2:
      return img.flipHorizontal(image);
    case 3:
      return img.copyRotate(image, angle: 180);
    case 4:
      return img.flipVertical(image);
    case 5:
      return img.flipHorizontal(img.copyRotate(image, angle: 90));
    case 6:
      return img.copyRotate(image, angle: 90);
    case 7:
      return img.flipHorizontal(img.copyRotate(image, angle: 270));
    case 8:
      return img.copyRotate(image, angle: 270);
    default:
      // Unrecognised value: treat as identity rather than guessing.
      return image;
  }
}
