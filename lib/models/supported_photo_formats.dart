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

  /// AVIF is AV1 inside the SAME ISO-BMFF container as HEIC, decoded by the
  /// same libheif entry point. Kept as its own set only so the routing
  /// predicate below can read clearly; it is NOT a separate decode path.
  static const Set<String> avifExtensions = {'.avif'};

  static const Set<String> jxlExtensions = {'.jxl'};

  /// Already-rendered bitmap containers with no cheap encoded bitstream that a
  /// full decoder can still turn into RGBA: TIFF via `package:image`, HEIC via
  /// the native libheif route in `ceyx` (phase 2). Membership here is what
  /// gives a format the widened `NativeImageNeedsRawDecode` escape hatch, the
  /// sidebar's sized-decode fallback and the export arm — all three derive
  /// from this one set.
  static const Set<String> bitmapDecodeExtensions = {
    ...tiffExtensions,
    ...heifExtensions,
    ...avifExtensions,
    ...jxlExtensions,
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

  /// Cheap-format sibling ranking, cheapest-to-display first. Order set by
  /// user ruling 2026-08-30 (Q6): jpg > heic > webp > avif > jxl, with png
  /// retained last. `.tif`/`.tiff` stay absent ON PURPOSE — a TIFF can be a
  /// RAW carrier, so its tier is decided by probing in [resolveBestFileToLoad].
  static const preferredLoadExtensions = <String>[
    '.jpg',
    '.jpeg',
    '.heic',
    '.heif',
    '.webp',
    '.avif',
    '.jxl',
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

  static bool isEncodedBitstreamPath(String path) {
    return engineBitstreamExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isBitmapDecodePath(String path) {
    return bitmapDecodeExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isTiffPath(String path) {
    return tiffExtensions.contains(p.extension(path).toLowerCase());
  }

  /// True for the containers the native libheif route decodes. Used by
  /// `full_decoder_dispatch.dart` to pick the HEIF arm; kept separate from
  /// [isBitmapDecodePath] because that set also contains TIFF, which goes to
  /// `package:image` instead.
  static bool isHeifPath(String path) {
    return heifExtensions.contains(p.extension(path).toLowerCase());
  }

  /// Everything the native libheif route decodes: HEIC, HEIF and AVIF.
  /// `full_decoder_dispatch.dart` picks the heif arm with THIS predicate, not
  /// [isHeifPath], precisely because AVIF must not get its own arm.
  static bool isLibheifPath(String path) {
    final ext = p.extension(path).toLowerCase();
    return heifExtensions.contains(ext) || avifExtensions.contains(ext);
  }

  static bool isJxlPath(String path) {
    return jxlExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool hasFullDecodeRoute(String path) {
    return fullDecodeExtensions.contains(p.extension(path).toLowerCase());
  }

  static String photoIdFor(File file) {
    return p.basenameWithoutExtension(file.path);
  }

  static File? _firstByPreferredExtension(List<File> files) {
    for (final ext in preferredLoadExtensions) {
      final index = files.indexWhere(
        (file) => p.extension(file.path).toLowerCase() == ext,
      );
      if (index != -1) return files[index];
    }
    return null;
  }

  static File? _supportedFallback(List<File> files) {
    // Never prefer a file this app cannot decode anywhere (e.g. a leftover
    // unsupported sibling such as a pre-removal .heic) over a decodable one.
    // Only fall through to an unsupported file if the whole group is
    // unsupported.
    final supported = files.where((file) => isSupportedPath(file.path));
    if (supported.isNotEmpty) return supported.first;
    return files.isNotEmpty ? files.first : null;
  }

  /// Synchronous, I/O-free sibling preference: the cheap-format extension
  /// ranking then the supported-file fallback. A TIFF is left in the fallback
  /// tier here because deciding whether it is cheap requires reading the file
  /// (see [resolveBestFileToLoad]); this remains the correct answer for every
  /// group that has no TIFF, and for a lone TIFF (the fallback returns it
  /// either way). Callers on the hot path use this via
  /// `PhotoItem.bestFileToLoad`, which prefers a scan-time resolved choice when
  /// one was computed.
  static File? bestFileToLoad(List<File> files) {
    return _firstByPreferredExtension(files) ?? _supportedFallback(files);
  }

  /// I/O-aware sibling preference. Extends [bestFileToLoad] with the TIFF
  /// cheap/expensive decision (user ruling, 2026-08-28 D2): a TIFF carrying an
  /// embedded already-rendered image is cheap to display and ranks just after
  /// PNG — above a DNG/RAW sibling — while a preview-less TIFF is a RAW carrier
  /// and stays in the expensive tier. [probe] answers "does this TIFF carry an
  /// embedded rendered image?" and is injected so the ranking can be tested
  /// without a real container; the scanner supplies the bounded IFD0 probe.
  ///
  /// The probe fires at most once per TIFF and only when it could change the
  /// choice: never when a cheap-extension sibling already won, and never for a
  /// group whose only supported candidates are TIFFs (they are returned
  /// regardless of tier).
  static Future<File?> resolveBestFileToLoad(
    List<File> files, {
    required Future<bool> Function(String path) probe,
  }) async {
    final preferred = _firstByPreferredExtension(files);
    if (preferred != null) return preferred;

    final tiffs = files.where((file) => isTiffPath(file.path)).toList();
    if (tiffs.isNotEmpty) {
      final hasNonTiffSupportedSibling = files.any(
        (file) => isSupportedPath(file.path) && !isTiffPath(file.path),
      );
      // With nothing else supported to lose to, the probe cannot change the
      // outcome — a TIFF is chosen either way — so skip the disk read.
      if (!hasNonTiffSupportedSibling) return tiffs.first;
      for (final tiff in tiffs) {
        if (await probe(tiff.path)) return tiff;
      }
    }

    return _supportedFallback(files);
  }
}
