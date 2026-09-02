import 'package:flutter/material.dart';
import '../../theme_tokens.dart';

/// The `paper` theme's own palette, for both brightnesses.
///
/// Tokens come from the `:root` blocks of the approved mockup,
/// `docs/logs/2026-09-01/mockup/paper/c1-desktop-light.html:39-80` and
/// `c1-desktop-dark.html` (same structure, dark `:root`), plus the palette
/// table in `docs/logs/2026-09-01/mockup/paper/NOTES.md` ("Palette —
/// `paper`"). Fitting them to Flutter slots:
///
/// | mockup role | light | dark | Flutter slot |
/// |---|---|---|---|
/// | app background (`--app`) | `#F6F2EA` | `#1A1815` | `scaffoldBackgroundColor` |
/// | raised surface (`--paper`) | `#FBF8F2` | `#232019` | `colorScheme.surface` |
/// | image well (`--sunk`) | `#EAE4D8` | `#131110` | `colorScheme.surfaceContainer` |
/// | primary text (`--ink`) | `#23201B` | `#EDE6DA` | `colorScheme.onSurface` |
/// | secondary text (`--ink2`) | `#6B6157` | `#A69B8C` | `colorScheme.onSurfaceVariant` |
/// | tertiary text (`--ink3`) | `#9C9285` | `#7A7063` | `PaperPalette.textFaint` |
/// | hairline (`--rule`) | `rgba(35,32,27,.13)` | `rgba(237,230,218,.14)` | `colorScheme.outlineVariant` |
/// | accent (`--accent`) | `#A2673E` | `#D08A55` | `colorScheme.primary` |
/// | type on accent (`--accent-ink`) | `#FFF9F2` | (accent-ink not separately listed; mockup uses `--accent-ink:#FFF9F2` for both, since the dark accent is already light enough for dark-on-accent to read wrong) | `PaperPalette.onAccent` |
/// | star (`--star`) | `#C08A22` | `#E8B44A` | `PaperPalette.star` |
/// | danger (`--danger`) | `#A6402F` | `#E0705C` | `colorScheme.error` |
/// | floating strip glass (`--glass-float`) | `rgba(251,248,242,.80)` | `rgba(35,32,25,.78)` | `PaperPalette.glassFloat` |
/// | status card ink (`--toast`) | `#26221D` | `#1B1815` | `PaperPalette.toastBackground` |
/// | status card bg (inverse, `--toast` on) | `#F4EFE6` | `#F1EBE0` | `PaperPalette.toastForeground` |
///
/// `HalcyonTokens.light`/`.dark` are registered unchanged on top (R1: dialogs
/// keep today's colours, not the paper palette).
@immutable
class PaperPalette extends ThemeExtension<PaperPalette> {
  const PaperPalette({
    required this.textFaint,
    required this.accentInk,
    required this.star,
    required this.glassFloat,
    required this.toastBackground,
    required this.toastForeground,
  });

  /// Tertiary text (`--ink3`).
  final Color textFaint;

  /// Type drawn ON the accent fill (`--accent-ink`), used by the welcome
  /// screen's Open Folder button.
  final Color accentInk;

  /// Star / semantic (`--star`).
  final Color star;

  /// Translucent strip background above the 90px default width
  /// (`--glass-float`), when the strip floats over the photo.
  final Color glassFloat;

  /// Status toast background (`--toast`, inverse of the app surface).
  final Color toastBackground;

  /// Status toast text (`--toast-ink`).
  final Color toastForeground;

  static const PaperPalette dark = PaperPalette(
    textFaint: Color(0xFF7A7063),
    accentInk: Color(0xFFFFF9F2),
    star: Color(0xFFE8B44A),
    glassFloat: Color(0xC7232019), // rgba(35,32,25,.78)
    toastBackground: Color(0xFF1B1815),
    toastForeground: Color(0xFFF1EBE0),
  );

  static const PaperPalette light = PaperPalette(
    textFaint: Color(0xFF9C9285),
    accentInk: Color(0xFFFFF9F2),
    star: Color(0xFFC08A22),
    glassFloat: Color(0xCCFBF8F2), // rgba(251,248,242,.80)
    toastBackground: Color(0xFF26221D),
    toastForeground: Color(0xFFF4EFE6),
  );

  static PaperPalette of(BuildContext context) =>
      Theme.of(context).extension<PaperPalette>() ?? dark;

  @override
  PaperPalette copyWith({
    Color? textFaint,
    Color? accentInk,
    Color? star,
    Color? glassFloat,
    Color? toastBackground,
    Color? toastForeground,
  }) {
    return PaperPalette(
      textFaint: textFaint ?? this.textFaint,
      accentInk: accentInk ?? this.accentInk,
      star: star ?? this.star,
      glassFloat: glassFloat ?? this.glassFloat,
      toastBackground: toastBackground ?? this.toastBackground,
      toastForeground: toastForeground ?? this.toastForeground,
    );
  }

  @override
  PaperPalette lerp(ThemeExtension<PaperPalette>? other, double t) {
    if (other is! PaperPalette) return this;
    return PaperPalette(
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      star: Color.lerp(star, other.star, t)!,
      glassFloat: Color.lerp(glassFloat, other.glassFloat, t)!,
      toastBackground: Color.lerp(toastBackground, other.toastBackground, t)!,
      toastForeground: Color.lerp(toastForeground, other.toastForeground, t)!,
    );
  }
}

/// Builds the `paper` theme's [ThemeData] for one brightness. Colours map 1:1
/// onto the mockup's `:root` palette (see [PaperPalette]); [HalcyonTokens] is
/// registered unchanged so the Settings and Rename dialogs keep today's
/// colours (R1).
ThemeData paperThemeData(Brightness brightness) {
  switch (brightness) {
    case Brightness.light:
      const scheme = ColorScheme.light(
        primary: Color(0xFFA2673E), // --accent
        onPrimary: Color(0xFFFFF9F2), // --accent-ink
        surface: Color(0xFFFBF8F2), // --paper raised surface
        surfaceContainer: Color(0xFFEAE4D8), // --sunk image well
        outlineVariant: Color(0x2123201B), // --rule rgba(35,32,27,.13)
        outline: Color(0x2123201B),
        onSurface: Color(0xFF23201B), // --ink primary text
        onSurfaceVariant: Color(0xFF6B6157), // --ink2 secondary text
        error: Color(0xFFA6402F), // --danger
      );
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF6F2EA), // --app
        dividerColor: Colors.transparent,
        colorScheme: scheme,
        popupMenuTheme: PopupMenuThemeData(color: scheme.surface, elevation: 8),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          space: 1,
          thickness: 1,
        ),
        extensions: const <ThemeExtension<dynamic>>[
          PaperPalette.light,
          HalcyonTokens.light,
        ],
      );
    case Brightness.dark:
      const scheme = ColorScheme.dark(
        primary: Color(0xFFD08A55), // --accent
        onPrimary: Color(0xFFFFF9F2), // --accent-ink
        surface: Color(0xFF232019), // --paper raised surface
        surfaceContainer: Color(0xFF131110), // --sunk image well
        outlineVariant: Color(0x24EDE6DA), // --rule rgba(237,230,218,.14)
        outline: Color(0x24EDE6DA),
        onSurface: Color(0xFFEDE6DA), // --ink primary text
        onSurfaceVariant: Color(0xFFA69B8C), // --ink2 secondary text
        error: Color(0xFFE0705C), // --danger
      );
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1A1815), // --app
        dividerColor: Colors.transparent,
        colorScheme: scheme,
        popupMenuTheme: PopupMenuThemeData(color: scheme.surface, elevation: 8),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          space: 1,
          thickness: 1,
        ),
        extensions: const <ThemeExtension<dynamic>>[
          PaperPalette.dark,
          HalcyonTokens.dark,
        ],
      );
  }
}
