import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TrashService {
  static const MethodChannel _channel = MethodChannel('halcyon/trash');

  static Future<void> trashFile(File file) async {
    try {
      await _channel.invokeMethod<void>('trashFile', {'path': file.path});
    } on PlatformException catch (e) {
      // The OS refused THIS file. Per-file failure; the batch continues.
      debugPrint("Failed to move file to trash: '${e.message}'.");
      throw TrashException(e.message ?? 'Failed to move file to trash');
    } on MissingPluginException catch (e) {
      // There is no trash bridge on this machine at all. A capability fact,
      // not a per-file error: the caller reroutes the whole batch to the
      // in-folder recycle path (photo_file_actions.dart:118).
      debugPrint("Trash service is unavailable: '${e.message}'.");
      throw const TrashException('Trash service is unavailable',
          bridgeUnavailable: true);
    }
  }
}

class TrashException implements Exception {
  const TrashException(this.message, {this.bridgeUnavailable = false});

  final String message;

  /// True when the platform registered no `halcyon/trash` handler, i.e. the
  /// system Trash is unreachable here for every file, not just this one.
  final bool bridgeUnavailable;

  @override
  String toString() => 'TrashException: $message';
}
