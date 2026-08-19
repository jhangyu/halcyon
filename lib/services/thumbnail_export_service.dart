import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/photo_item.dart';
import '../models/supported_photo_formats.dart';
import 'native_thumbnail_service.dart';

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
/// The default implementation goes through the `halcyon/thumbnail` platform
/// channel; tests inject a fake so this service never touches a platform
/// channel.
typedef ExportBytesFetch = Future<Uint8List?> Function(String path);

class ThumbnailExportService {
  ThumbnailExportService({ExportBytesFetch? fetchBytes})
    : _fetchBytes = fetchBytes ?? _defaultFetch;

  final ExportBytesFetch _fetchBytes;

  static Future<Uint8List?> _defaultFetch(String path) {
    return NativeThumbnailService.getThumbnail(
      path,
      purpose: ImageRequestPurpose.export,
    );
  }

  // ponytail: concurrency ceiling of 4 — a RAW full decode can cost hundreds
  // of MB in flight, so letting every starred item decode at once risks OOM
  // on large batches. The native handler already dispatches to a concurrent
  // queue, so 4 in-flight `invokeMethod` calls genuinely run in parallel.
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
