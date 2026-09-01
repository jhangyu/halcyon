import 'package:flutter/material.dart';
import '../../theme_tokens.dart';

/// The `gallery` theme's own palette, for both brightnesses.
///
/// The tokens come from the `:root` blocks of the desktop mockup,
/// `docs/logs/2026-09-01/mockup/gallery/c1-desktop-light.html:69-88` and
/// `c1-desktop-dark.html:69-88`. Fitting them to Flutter slots:
///
/// | mockup role | light | dark | Flutter slot |
/// |---|---|---|---|
/// | gutter / room (`--canvas`) | `#FAF9F7` | `#141414` | `scaffoldBackgroundColor` |
/// | mount behind print (`--mat`) | `#F1EFEB` | `#1B1B1C` | `GalleryPalette.mat` |
/// | strip & panel surface (`--rail`) | `#FFFFFF` | `#1E1E20` | `colorScheme.surface` |
/// | inset well / track (`--sunk`) | `#F6F5F2` | `#242426` | `colorScheme.surfaceContainer` |
/// | hairline (`--hair`) | `#E3DFD8` | `#2E2E31` | `colorScheme.outlineVariant` |
/// | hairline strong (`--hair-strong`) | `#D2CDC4` | `#3C3C40` | `colorScheme.outline` |
/// | primary text (`--ink`) | `#1C1B19` | `#E8E6E2` | `colorScheme.onSurface` |
/// | secondary text (`--ink-dim`) | `#6E6A64` | `#99958F` | `colorScheme.onSurfaceVariant` |
/// | tertiary (`--ink-faint`) | `#9C9791` | `#6B6863` | `GalleryPalette.textFaint` |
/// | accent, slate blue (`--accent`) | `#3F5D72` | `#7FA3BC` | `colorScheme.primary` |
/// | star, brass (`--star`) | `#B08328` | `#D7A54A` | `GalleryPalette.star` |
/// | danger, oxide (`--danger`) | `#A6432F` | `#C86B58` | `colorScheme.error` |
///
/// `HalcyonTokens.light` / `.dark` are registered on top, unchanged, so the
/// Settings and Rename dialogs render exactly as today (T5 constraint, R1
/// evidence, contract AC #7). All widget-facing gallery code is expected to
/// read the theme through these slots; no colour literal should live anywhere
/// else under `layout/gallery/`.
@immutable
class GalleryPalette extends ThemeExtension<GalleryPalette> {
  const GalleryPalette({
    required this.mat,
    required this.textFaint,
    required this.star,
  });

  /// Mount behind the print (`--mat`).
  final Color mat;
  /// Tertiary text (`--ink-faint`).
  final Color textFaint;
  /// Star / brass, semantic (`--star`).
  final Color star;

  static const GalleryPalette dark = GalleryPalette(
    mat: Color(0xFF1B1B1C),
    textFaint: Color(0xFF6B6863),
    star: Color(0xFFD7A54A),
  );

  static const GalleryPalette light = GalleryPalette(
    mat: Color(0xFFF1EFEB),
    textFaint: Color(0xFF9C9791),
    star: Color(0xFFB08328),
  );

  static GalleryPalette of(BuildContext context) =>
      Theme.of(context).extension<GalleryPalette>() ?? dark;

  @override
  GalleryPalette copyWith({Color? mat, Color? textFaint, Color? star}) {
    return GalleryPalette(
      mat: mat ?? this.mat,
      textFaint: textFaint ?? this.textFaint,
      star: star ?? this.star,
    );
  }

  @override
  GalleryPalette lerp(ThemeExtension<GalleryPalette>? other, double t) {
    if (other is! GalleryPalette) return this;
    return GalleryPalette(
      mat: Color.lerp(mat, other.mat, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      star: Color.lerp(star, other.star, t)!,
    );
  }
}

/// Builds the `gallery` theme's [ThemeData] for one brightness.
///
/// Colours map 1:1 onto the desktop mockup palette (see [GalleryPalette]).
/// Each hex literal appears exactly once per brightness; the colour scheme is
/// built first and the shared chrome slots (popup menu, dividers) reference it,
/// so there is a single source for every hue. [HalcyonTokens] is registered
/// unchanged so the Settings and Rename dialogs render exactly as today
/// (contract AC #7); the gallery chrome reads the `ColorScheme` and
/// [GalleryPalette] slots above instead.
ThemeData galleryThemeData(Brightness brightness) {
  switch (brightness) {
    case Brightness.light:
      const scheme = ColorScheme.light(
        primary: Color(0xFF3F5D72), // --accent slate blue
        onPrimary: Colors.white,
        surface: Color(0xFFFFFFFF), // --rail strip & panel surface
        surfaceContainer: Color(0xFFF6F5F2), // --sunk inset well / track
        outlineVariant: Color(0xFFE3DFD8), // --hair
        outline: Color(0xFFD2CDC4), // --hair-strong
        onSurface: Color(0xFF1C1B19), // --ink primary text
        onSurfaceVariant: Color(0xFF6E6A64), // --ink-dim secondary text
        error: Color(0xFFA6432F), // --danger oxide
      );
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        // --canvas gutter / room wall
        scaffoldBackgroundColor: const Color(0xFFFAF9F7),
        dividerColor: Colors.transparent,
        colorScheme: scheme,
        popupMenuTheme: PopupMenuThemeData(
          color: scheme.surface, // --rail
          elevation: 8,
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, // --hair
          space: 1,
          thickness: 1,
        ),
        extensions: const <ThemeExtension<dynamic>>[
          GalleryPalette.light,
          HalcyonTokens.light,
        ],
      );
    case Brightness.dark:
      const scheme = ColorScheme.dark(
        primary: Color(0xFF7FA3BC), // --accent slate blue
        onPrimary: Colors.white,
        surface: Color(0xFF1E1E20), // --rail strip & panel surface
        surfaceContainer: Color(0xFF242426), // --sunk inset well / track
        outlineVariant: Color(0xFF2E2E31), // --hair
        outline: Color(0xFF3C3C40), // --hair-strong
        onSurface: Color(0xFFE8E6E2), // --ink primary text
        onSurfaceVariant: Color(0xFF99958F), // --ink-dim secondary text
        error: Color(0xFFC86B58), // --danger oxide
      );
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        // --canvas gutter / room wall
        scaffoldBackgroundColor: const Color(0xFF141414),
        dividerColor: Colors.transparent,
        colorScheme: scheme,
        popupMenuTheme: PopupMenuThemeData(
          color: scheme.surface, // --rail
          elevation: 8,
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, // --hair
          space: 1,
          thickness: 1,
        ),
        extensions: const <ThemeExtension<dynamic>>[
          GalleryPalette.dark,
          HalcyonTokens.dark,
        ],
      );
  }
}