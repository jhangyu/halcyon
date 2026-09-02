import 'package:flutter/material.dart';
import '../../theme_tokens.dart';

/// The `darkroom` theme's own palette, for both brightnesses.
///
/// Tokens lifted verbatim from the `:root` blocks of the approved mockup,
/// `docs/logs/2026-09-01/mockup/darkroom/c2-desktop-light.html:63-102` and
/// `c2-desktop-dark.html:63-102`. Fitting them to Flutter slots:
///
/// | mockup role | light | dark | Flutter slot |
/// |---|---|---|---|
/// | room wall (`--ground`) | `#E7E9E4` | `#0C0D0C` | `scaffoldBackgroundColor` |
/// | mount/stage (`--stage`) | `#F0F2ED` | `#121312` | `DarkroomPalette.stage` |
/// | picture column surface (`--pane`) | `#F1F2EF` | `#171917` | `colorScheme.surface` |
/// | inset well (`--surface`) | `#E8EAE5` | `#232622` | `colorScheme.surfaceContainer` |
/// | hairline (`--line`) | `#C7CAC2` | `#2E322C` | `colorScheme.outlineVariant` |
/// | hairline strong (`--hair-strong`) | rgba(0,0,0,.26) | rgba(255,255,255,.20) | `colorScheme.outline` |
/// | primary text (`--text`) | `#1E201C` | `#E6E6E0` | `colorScheme.onSurface` |
/// | secondary text (`--dim`) | `#63665E` | `#989A92` | `colorScheme.onSurfaceVariant` |
/// | tertiary (`--faint`) | `#93968C` | `#67695F` | `DarkroomPalette.textFaint` |
/// | accent, moss green (`--accent`) | `#4C6A46` | `#9BB394` | `colorScheme.primary` |
/// | type on the accent (`--accent-ink`) | `#FFFFFF` | `#0C0D0C` | `DarkroomPalette.onAccent` |
/// | accent wash (`--accent-wash`) | rgba(76,106,70,.14) | rgba(155,179,148,.16) | `DarkroomPalette.accentWash` |
/// | star, gold (`--star`) | `#E9B84C` | `#E9B84C` | `DarkroomPalette.star` |
/// | danger (`--danger`) | `#C7362B` | `#D9695C` | `colorScheme.error` |
/// | type over the photo (`--photo-ink`) | `#F2F1EE` | `#F2F1EE` | `DarkroomPalette.photoInk` |
/// | dim type over the photo (`--photo-ink-dim`) | `#C9C7C2` | `#C9C7C2` | `DarkroomPalette.photoInkDim` |
///
/// `HalcyonTokens.light` / `.dark` are registered on top, unchanged, so the
/// Settings dialog renders in today's colours (mockup ruling R1: dialogs keep
/// `--dlg-*` tokens, never the theme palette).
@immutable
class DarkroomPalette extends ThemeExtension<DarkroomPalette> {
  const DarkroomPalette({
    required this.stage,
    required this.textFaint,
    required this.star,
    required this.onAccent,
    required this.accentWash,
    required this.photoInk,
    required this.photoInkDim,
  });

  /// Mount/stage behind the print (`--stage`).
  final Color stage;

  /// Tertiary text (`--faint`).
  final Color textFaint;

  /// Star, semantic (`--star`).
  final Color star;

  /// Type drawn ON the accent fill (`--accent-ink`).
  final Color onAccent;

  /// The selection wash used for "this one is live" (`--accent-wash`).
  final Color accentWash;

  /// Type floating over the photograph (`--photo-ink`).
  final Color photoInk;

  /// Dim type floating over the photograph (`--photo-ink-dim`).
  final Color photoInkDim;

  static const DarkroomPalette dark = DarkroomPalette(
    stage: Color(0xFF121312),
    textFaint: Color(0xFF67695F),
    star: Color(0xFFE9B84C),
    onAccent: Color(0xFF0C0D0C),
    accentWash: Color(0x289BB394), // rgba(155,179,148,.16)
    photoInk: Color(0xFFF2F1EE),
    photoInkDim: Color(0xFFC9C7C2),
  );

  static const DarkroomPalette light = DarkroomPalette(
    stage: Color(0xFFF0F2ED),
    textFaint: Color(0xFF93968C),
    star: Color(0xFFE9B84C),
    onAccent: Color(0xFFFFFFFF),
    accentWash: Color(0x244C6A46), // rgba(76,106,70,.14)
    photoInk: Color(0xFFF2F1EE),
    photoInkDim: Color(0xFFC9C7C2),
  );

  static DarkroomPalette of(BuildContext context) =>
      Theme.of(context).extension<DarkroomPalette>() ?? dark;

  @override
  DarkroomPalette copyWith({
    Color? stage,
    Color? textFaint,
    Color? star,
    Color? onAccent,
    Color? accentWash,
    Color? photoInk,
    Color? photoInkDim,
  }) {
    return DarkroomPalette(
      stage: stage ?? this.stage,
      textFaint: textFaint ?? this.textFaint,
      star: star ?? this.star,
      onAccent: onAccent ?? this.onAccent,
      accentWash: accentWash ?? this.accentWash,
      photoInk: photoInk ?? this.photoInk,
      photoInkDim: photoInkDim ?? this.photoInkDim,
    );
  }

  @override
  DarkroomPalette lerp(ThemeExtension<DarkroomPalette>? other, double t) {
    if (other is! DarkroomPalette) return this;
    return DarkroomPalette(
      stage: Color.lerp(stage, other.stage, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      star: Color.lerp(star, other.star, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentWash: Color.lerp(accentWash, other.accentWash, t)!,
      photoInk: Color.lerp(photoInk, other.photoInk, t)!,
      photoInkDim: Color.lerp(photoInkDim, other.photoInkDim, t)!,
    );
  }
}

/// Builds the `darkroom` theme's [ThemeData] for one brightness.
ThemeData darkroomThemeData(Brightness brightness) {
  switch (brightness) {
    case Brightness.light:
      const scheme = ColorScheme.light(
        primary: Color(0xFF4C6A46), // --accent moss
        onPrimary: Colors.white,
        surface: Color(0xFFF1F2EF), // --pane
        surfaceContainer: Color(0xFFE8EAE5), // --surface
        outlineVariant: Color(0xFFC7CAC2), // --line
        outline: Color(0x42000000), // --hair-strong rgba(0,0,0,.26)
        onSurface: Color(0xFF1E201C), // --text
        onSurfaceVariant: Color(0xFF63665E), // --dim
        error: Color(0xFFC7362B), // --danger
      );
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFE7E9E4), // --ground
        dividerColor: Colors.transparent,
        colorScheme: scheme,
        popupMenuTheme: PopupMenuThemeData(
          color: scheme.surface, // --pane
          elevation: 8,
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          space: 1,
          thickness: 1,
        ),
        extensions: const <ThemeExtension<dynamic>>[
          DarkroomPalette.light,
          HalcyonTokens.light,
        ],
      );
    case Brightness.dark:
      const scheme = ColorScheme.dark(
        primary: Color(0xFF9BB394), // --accent moss
        onPrimary: Colors.black,
        surface: Color(0xFF171917), // --pane
        surfaceContainer: Color(0xFF232622), // --surface
        outlineVariant: Color(0xFF2E322C), // --line
        outline: Color(0x33FFFFFF), // --hair-strong rgba(255,255,255,.20)
        onSurface: Color(0xFFE6E6E0), // --text
        onSurfaceVariant: Color(0xFF989A92), // --dim
        error: Color(0xFFD9695C), // --danger
      );
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0C0D0C), // --ground
        dividerColor: Colors.transparent,
        colorScheme: scheme,
        popupMenuTheme: PopupMenuThemeData(
          color: scheme.surface,
          elevation: 8,
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          space: 1,
          thickness: 1,
        ),
        extensions: const <ThemeExtension<dynamic>>[
          DarkroomPalette.dark,
          HalcyonTokens.dark,
        ],
      );
  }
}
