import 'package:flutter/material.dart';

import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;

import '../gallery/gallery_palette.dart';

/// The EXIF corner caption (ruling R4), drawn in the museum-label manner: no
/// panel, no fill, type only, right-aligned over the photo's bottom-right
/// corner.
///
/// Lives in `common/`, not `gallery/`, because all three themes' mockups carry
/// a caption; it takes its colours from the ambient theme slots
/// ([ThemeData.colorScheme].`onSurfaceVariant`, `.`outline` and
/// [GalleryPalette].`textFaint`), so it needs no theme-specific branch.
///
/// Desktop (`.exif`, `c1-desktop-{light,dark}.html:367-384`): a right-aligned
/// column reading NAME, rule, camera, exposure — the museum-label order. The
/// file name (revision 2026-09-02, `.exif .file`) is 13px letterSpacing 0.03em
/// in `onSurface`, the only full-ink item and the largest type in the block; it
/// moved here from the 90px sidebar plate, where it truncated on almost every
/// real name. A 44×1 rule in `outline` follows it, then camera 9.5px uppercase
/// letterSpacing 0.14em in `textFaint`, then the body line 10.5px letterSpacing
/// 0.1em in `onSurfaceVariant`.
///
/// The rule is a single separator, drawn once between the block above it and
/// the block below: with a file name it sits under the name (mockup order
/// `.file` / `.rule` / `.cam` / `.body`), and with no name it falls back to
/// separating camera from body, which is where it sat before the revision.
///
/// Mobile (`.label .exif`, `c3-mobile-light.html:142`, sample at `:272`): one
/// 9.5px line, letterSpacing 0.06em, `onSurfaceVariant`, the camera included
/// inline.
///
/// An unread or unreadable photo renders nothing: `exif == null` or every
/// present field being null produces [SizedBox.shrink] — no placeholder text,
/// no dashes, no skeleton.
class ExifCaption extends StatelessWidget {
  const ExifCaption({
    super.key,
    required this.exif,
    this.fileName,
    this.compact = false,
    this.alignment = CrossAxisAlignment.end,
  });

  final ExifMetadata? exif;

  /// The photo's display name, drawn as the label's title line (desktop only).
  /// Null (or empty) draws no title, and the caption reads exactly as it did
  /// before the 2026-09-02 revision.
  final String? fileName;

  /// Mobile: one line, no rule, no camera line. Desktop: three-part stack.
  final bool compact;

  /// Text-column alignment. Gallery keeps the default right-aligned museum
  /// label (bottom-right corner); paper's mockup places the caption bottom-left
  /// with left-aligned text, so themes may pass [CrossAxisAlignment.start].
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final exif = this.exif;
    final name = compact ? null : _blankToNull(fileName);
    final camera = exif?.camera;
    final body = exif == null ? null : _bodyLine(exif);
    // Nothing to show at all — not even a name. A photo whose EXIF is unread
    // or unreadable still gets its title line, which is why this can no longer
    // return early on `exif == null` alone.
    if (name == null && camera == null && body == null) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final faint = GalleryPalette.of(context).textFaint;

    if (compact) {
      // Mobile: `Nikon Z 8 · 85 mm · ƒ/5.6 · 1/500 · ISO 200` — camera
      // included inline, no rule, one faint-dim line. On a photo there is no
      // readable surface background, so the mobile line carries its own base.
      final text = [
        if (camera != null) camera,
        if (body != null) body,
      ].join(' · ');
      return Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          letterSpacing: 0.06 * 9.5, // 0.06 em at 9.5px
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    // One rule, drawn under the title when there is one, otherwise between
    // camera and body — and never when there is nothing on both sides of it.
    final ruleAfterName = name != null && (camera != null || body != null);
    final ruleAfterCamera = name == null && camera != null && body != null;

    return Column(
      crossAxisAlignment: alignment,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (name != null)
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              letterSpacing: 0.03 * 13, // 0.03 em at 13px
              height: 1,
              color: scheme.onSurface,
            ),
          ),
        if (ruleAfterName) _rule(scheme),
        if (camera != null)
          Text(
            camera,
            style: TextStyle(
              fontSize: 9.5,
              letterSpacing: 0.14 * 9.5, // 0.14 em at 9.5px
              height: 1,
              color: faint,
            ),
          ),
        if (ruleAfterCamera) _rule(scheme),
        if (body != null)
          Text(
            body,
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.1 * 10.5, // 0.1 em at 10.5px
              height: 1,
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  /// The 44×1 hairline (`.exif .rule`, `margin:4px 0 3px`). Widened from 34 in
  /// the 2026-09-02 mockup revision.
  static Widget _rule(ColorScheme scheme) => Container(
    width: 44,
    height: 1,
    margin: const EdgeInsets.only(top: 4, bottom: 3),
    color: scheme.outline,
  );

  static String? _blankToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// The shooting-parameters line: focal, aperture, shutter, ISO joined with
  /// `' · '` between PRESENT fields only — no leading, trailing, or doubled
  /// separators when a field is missing. Null (every field absent) when none
  /// is present.
  String? _bodyLine(ExifMetadata exif) {
    final focal = exif.focalLength;
    final aperture = exif.aperture;
    final shutter = exif.shutter;
    final iso = exif.iso;

    final parts = <String>[
      if (focal != null) '${focal.round()} mm',
      if (aperture != null) 'ƒ/${_trimAperture(aperture)}',
      if (shutter != null) shutter,
      if (iso != null) 'ISO $iso',
    ];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  /// `5.6` stays `5.6`; `8.0` becomes `8` (the mockup writes `ƒ/5.6`, `ƒ/8`).
  static String _trimAperture(double aperture) => aperture == aperture.roundToDouble()
      ? aperture.round().toString()
      : aperture.toString();
}