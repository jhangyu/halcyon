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
/// Desktop (`.exif`, `c1-desktop-light.html:314-321` and the body at `:406`):
/// a right-aligned column — camera 9.5px uppercase letterSpacing 0.14em in
/// `textFaint`; a 34×1 rule in `outline`; then the body line 10.5px
/// letterSpacing 0.1em in `onSurfaceVariant`.
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
    this.compact = false,
  });

  final ExifMetadata? exif;

  /// Mobile: one line, no rule, no camera line. Desktop: three-part stack.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final exif = this.exif;
    if (exif == null) return const SizedBox.shrink();

    final camera = exif.camera;
    final body = _bodyLine(exif);
    if (body == null && camera == null) return const SizedBox.shrink();

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
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
        // The 34×1 rule separates the camera name from the body; with either
        // missing there is nothing to separate, so it is omitted too.
        if (camera != null && body != null) ...[
          Container(
            width: 34,
            height: 1,
            margin: const EdgeInsets.only(top: 2, bottom: 2),
            color: scheme.outline,
          ),
        ],
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