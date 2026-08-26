import 'dart:io';

import 'package:ceyx/ceyx.dart' show kSupportedDecodeExtensions;
import 'package:path/path.dart' as p;

class SupportedPhotoFormats {
  /// Extensions the Ceyx engine can actually decode, derived from
  /// `kSupportedDecodeExtensions` rather than restated, so a future engine
  /// addition cannot silently desync (contract: docs/logs/2026-08-26/raw-support-contract.md).
  static final Set<String> decodableExtensions = kSupportedDecodeExtensions
      .map((ext) => '.${ext.toLowerCase()}')
      .toSet();

  /// D2 — formats the engine cannot decode but stay browsable via embedded
  /// preview only (Canon CR2, Phase One IIQ, Minolta MRW).
  static const Set<String> browseOnlyRawExtensions = {
    '.cr2',
    '.iiq',
    '.mrw',
  };

  static Set<String> get rawExtensions =>
      decodableExtensions.union(browseOnlyRawExtensions);

  static Set<String> get supportedExtensions =>
      {'.jpg', '.jpeg', '.png'}.union(rawExtensions);

  static const preferredLoadExtensions = <String>[
    '.jpg',
    '.jpeg',
    '.png',
  ];

  static bool isSupportedPath(String path) {
    return supportedExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isRawPath(String path) {
    return rawExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isDecodablePath(String path) {
    return decodableExtensions.contains(p.extension(path).toLowerCase());
  }

  static String photoIdFor(File file) {
    return p.basenameWithoutExtension(file.path);
  }

  static File? bestFileToLoad(List<File> files) {
    for (final ext in preferredLoadExtensions) {
      final index = files.indexWhere(
        (file) => p.extension(file.path).toLowerCase() == ext,
      );
      if (index != -1) return files[index];
    }

    // Fallback: never prefer a file this app cannot decode anywhere (e.g. a
    // leftover unsupported sibling such as a pre-removal .heic) over a
    // decodable one. Only fall through to an unsupported file if the whole
    // group is unsupported.
    final supported = files.where((file) => isSupportedPath(file.path));
    if (supported.isNotEmpty) return supported.first;

    return files.isNotEmpty ? files.first : null;
  }
}
