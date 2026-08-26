import 'dart:io';
import 'dart:isolate';

import 'package:exif/exif.dart' as pkg;
import 'package:flutter/foundation.dart';

import '../../models/rename_rule.dart';

/// Injection seam for reading EXIF for a batch of paths, mirroring the
/// `DngFullDecoder` typedef pattern so `AppState` can be tested without a
/// platform channel. Returned list is index-aligned with the input; an entry
/// is null when nothing could be read.
typedef ExifBatchReader = Future<List<ExifMetadata?>> Function(
  List<String> paths, {
  void Function(int done, int total)? onProgress,
});

/// Paths per channel call. Large enough that 10,000 photos cost 20 calls, small
/// enough that progress updates stay smooth.
const int kExifChunkSize = 500;

class ExifMetadataService {
  /// Reads metadata for [paths], chunked, order preserved.
  ///
  /// M6 F-14: the native channel is deleted; the package/isolate path —
  /// formerly the fallback and always the reference implementation — is the
  /// only path everywhere (matrix F-14, parity gold standard per
  /// m6-spec-contract §3). Chunking is retained so a huge folder still
  /// yields incremental progress rather than one giant `Future.wait`.
  static Future<List<ExifMetadata?>> readBatch(
    List<String> paths, {
    void Function(int done, int total)? onProgress,
  }) async {
    final results = <ExifMetadata?>[];
    for (var start = 0; start < paths.length; start += kExifChunkSize) {
      final end = (start + kExifChunkSize).clamp(0, paths.length);
      final chunk = paths.sublist(start, end);
      results.addAll(await _readChunk(chunk));
      onProgress?.call(end, paths.length);
    }
    return results;
  }

  static Future<List<ExifMetadata?>> _readChunk(List<String> chunk) {
    return Future.wait(chunk.map(readWithPackage));
  }

  /// Decodes one native map. Public because this shape — not the channel — is
  /// what the tests can pin down.
  static ExifMetadata? metadataFromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    return ExifMetadata(
      captureDate: _parseDate(map['captureDate']),
      camera: _string(map['camera']),
      lens: _string(map['lens']),
      make: _string(map['make']),
      artist: _string(map['artist']),
      shutter: _string(map['shutter']),
      aperture: _double(map['aperture']),
      focalLength: _double(map['focalLength']),
      gpsImgDirection: _double(map['direction']),
      iso: map['iso'] is int ? map['iso'] as int : null,
    );
  }

  /// Non-macOS fallback. Runs off the UI isolate because parsing a RAW header
  /// reads and scans megabytes.
  static Future<ExifMetadata?> readWithPackage(String path) async {
    try {
      return await Isolate.run(() => _parseWithPackage(path));
    } catch (e) {
      // Only print in debug builds when the file actually exists on disk —
      // tests with fake paths (e.g. /nonexistent/...) would otherwise spam
      // the log with hundreds of lines per gate run.
      assert(() {
        if (File(path).existsSync()) {
          debugPrint('EXIF package read failed for $path: $e');
        }
        return true;
      }());
      return null;
    }
  }

  static Future<ExifMetadata?> _parseWithPackage(String path) async {
    final tags = await pkg.readExifFromFile(File(path));
    if (tags.isEmpty) return null;
    String? tag(String key) => tags[key]?.printable.trim();
    return ExifMetadata(
      captureDate: _parseDate(tag('EXIF DateTimeOriginal')),
      camera: _blankToNull(tag('Image Model')),
      lens: _blankToNull(tag('EXIF LensModel')),
      make: _blankToNull(tag('Image Make')),
      artist: _blankToNull(tag('Image Artist')),
      shutter: _blankToNull(tag('EXIF ExposureTime')),
      aperture: _ratio(tag('EXIF FNumber')),
      focalLength: _ratio(tag('EXIF FocalLength')),
      gpsImgDirection: _ratio(tag('GPS GPSImgDirection')),
      iso: int.tryParse(tag('EXIF ISOSpeedRatings') ?? ''),
    );
  }

  /// EXIF dates are `yyyy:MM:dd HH:mm:ss`, which `DateTime.parse` rejects.
  static DateTime? _parseDate(Object? value) {
    if (value is! String) return null;
    final match = RegExp(
      r'^(\d{4})\D(\d{2})\D(\d{2})\D(\d{2})\D(\d{2})\D(\d{2})',
    ).firstMatch(value.trim());
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String? _blankToNull(String? value) =>
      value == null || value.isEmpty ? null : value;

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return null;
  }

  /// The package prints rationals as `28/10`; a plain number passes through.
  static double? _ratio(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split('/');
    if (parts.length == 2) {
      final n = double.tryParse(parts[0]);
      final d = double.tryParse(parts[1]);
      if (n != null && d != null && d != 0) return n / d;
      return null;
    }
    return double.tryParse(value);
  }
}
