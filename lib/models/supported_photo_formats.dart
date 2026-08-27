import 'dart:io';

import 'package:ceyx/ceyx.dart' show kSupportedDecodeExtensions;
import 'package:path/path.dart' as p;

class SupportedPhotoFormats {
  /// Extensions the Ceyx engine can actually decode, derived from
  /// `kSupportedDecodeExtensions` rather than restated, so a future engine
  /// addition cannot silently desync (contract: docs/logs/2026-08-26/raw-support-contract.md).
  static final Set<String> decodableExtensions = Set.unmodifiable(
    kSupportedDecodeExtensions.map((ext) => '.${ext.toLowerCase()}'),
  );

  /// D2 — formats the engine cannot decode but stay browsable via embedded
  /// preview only (Canon CR2, Phase One IIQ, Minolta MRW).
  static const Set<String> browseOnlyRawExtensions = {
    '.cr2',
    '.iiq',
    '.mrw',
  };

  // static final: computed once (folder scans call isSupportedPath/isRawPath
  // per entry, so these must not re-allocate on every call — they were const
  // before decodableExtensions made them derived). Unmodifiable so callers
  // can't corrupt process-global format policy via `.add`.
  static final Set<String> rawExtensions = Set.unmodifiable(
    decodableExtensions.union(browseOnlyRawExtensions),
  );

  /// Formats the Flutter engine's own codec (Skia/Impeller `SkCodec`) reads
  /// directly from the file's bytes. ONE definition, consumed both by the
  /// folder-scan whitelist below and by `dart_image_loader.dart`'s
  /// encoded-bitstream branch, so the two cannot desync (the same
  /// "derive, don't restate" rule the 2026-08-26 contract imposed on the RAW
  /// list). Animated WebP is decoded to its first frame only; Halcyon is a
  /// still-photo triage tool.
  static const Set<String> engineBitstreamExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  };

  static const Set<String> tiffExtensions = {'.tif', '.tiff'};

  static const Set<String> heifExtensions = {'.heic', '.heif'};

  /// Already-rendered bitmap containers with no cheap encoded bitstream that a
  /// full decoder can still turn into RGBA: TIFF via `package:image`, HEIC via
  /// the native libheif route in `ceyx` (phase 2). Membership here is what
  /// gives a format the widened `NativeImageNeedsRawDecode` escape hatch, the
  /// sidebar's sized-decode fallback and the export arm — all three derive
  /// from this one set.
  static const Set<String> bitmapDecodeExtensions = {
    ...tiffExtensions,
    ...heifExtensions,
  };

  static final Set<String> supportedExtensions = Set.unmodifiable(
    engineBitstreamExtensions.union(bitmapDecodeExtensions).union(rawExtensions),
  );

  /// Everything with a route to RGBA through the `DngFullDecoder` seam:
  /// engine-decodable RAW plus the bitmap containers above. Deliberately
  /// distinct from [decodableExtensions] — AD-021's `minLongEdge` floor and
  /// AD-022's malformed-container finding stay gated on THAT set, because both
  /// are statements about embedded previews in a RAW container.
  static final Set<String> fullDecodeExtensions = Set.unmodifiable(
    decodableExtensions.union(bitmapDecodeExtensions),
  );

  /// `.webp` sits AFTER `.png`: a WebP sibling of a RAW should win (it is a
  /// rendered bitstream), but a JPEG or PNG sibling stays preferred because
  /// those are what cameras and prior exports produce. `.tif`/`.tiff` are
  /// absent on purpose — a TIFF must not outrank a JPEG sibling, and
  /// [bestFileToLoad]'s supported-file fallback already picks it up when the
  /// whole group is TIFF.
  static const preferredLoadExtensions = <String>[
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
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

  static bool isEncodedBitstreamPath(String path) {
    return engineBitstreamExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isBitmapDecodePath(String path) {
    return bitmapDecodeExtensions.contains(p.extension(path).toLowerCase());
  }

  /// True for the containers the native libheif route decodes. Used by
  /// `full_decoder_dispatch.dart` to pick the HEIF arm; kept separate from
  /// [isBitmapDecodePath] because that set also contains TIFF, which goes to
  /// `package:image` instead.
  static bool isHeifPath(String path) {
    return heifExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool hasFullDecodeRoute(String path) {
    return fullDecodeExtensions.contains(p.extension(path).toLowerCase());
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
