import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TrashService {
  static const MethodChannel _channel = MethodChannel('halcyon/trash');

  static Future<void> trashFile(File file) async {
    try {
      await _channel.invokeMethod<void>('trashFile', {'path': file.path});
    } on PlatformException catch (e) {
      debugPrint("Failed to move file to trash: '${e.message}'.");
      throw TrashException(e.message ?? 'Failed to move file to trash');
    } on MissingPluginException catch (e) {
      debugPrint("Trash service is unavailable: '${e.message}'.");
      throw TrashException('Trash service is unavailable');
    }
  }
}

class TrashException implements Exception {
  const TrashException(this.message);

  final String message;

  @override
  String toString() => 'TrashException: $message';
}
