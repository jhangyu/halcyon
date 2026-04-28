import 'dart:io';

import 'package:path/path.dart' as p;

class SupportedPhotoFormats {
  static const supportedExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.arw',
    '.rw2',
    '.dng',
    '.heic',
    '.png',
  };

  static const preferredLoadExtensions = <String>[
    '.jpg',
    '.jpeg',
    '.png',
    '.heic',
  ];

  static const rawExtensions = <String>{
    '.arw',
    '.rw2',
    '.dng',
    '.cr2',
    '.nef',
    '.orf',
  };

  static bool isSupportedPath(String path) {
    return supportedExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isRawPath(String path) {
    return rawExtensions.contains(p.extension(path).toLowerCase());
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

    return files.isNotEmpty ? files.first : null;
  }
}
