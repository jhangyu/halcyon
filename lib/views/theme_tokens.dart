import 'package:flutter/material.dart';

/// The app's design tokens, as a ThemeExtension.
///
/// Three colour systems used to coexist: `main.dart`'s ThemeData, a private
/// `_Tokens` class inside `rename_dialog.dart`, and bare `Colors.*` literals
/// in `sidebar_view.dart`. This is the one source; the values are lifted
/// unchanged from `rename_dialog.dart`'s `_Tokens` (the mockup's palette,
/// docs/mockups/exif-rename/variant-2-twopane.html, plus a light-mode
/// counterpart), so nothing looks different except the sidebar literals that
/// had no token before.
///
/// `_Tokens` had 12 fields, not the 6 in an earlier draft of this class — all
/// 12 are kept here rather than dropping the 6 with no obvious counterpart
/// (surface/input/border/borderSoft/success plus a light/dark `pane` vs
/// `dialog` split).
@immutable
class HalcyonTokens extends ThemeExtension<HalcyonTokens> {
  const HalcyonTokens({
    required this.pane,
    required this.dialog,
    required this.surface,
    required this.input,
    required this.border,
    required this.borderSoft,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.success,
    required this.danger,
    required this.starred,
  });

  final Color pane;
  final Color dialog;
  final Color surface;
  final Color input;
  final Color border;
  final Color borderSoft;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color accent;
  final Color success;
  final Color danger;
  // Moved verbatim from sidebar_view.dart's `Colors.amber` literal (the
  // starred-photo icon color) -- not a new shade, just this D4 sweep's last
  // inline literal given a name. Same value both modes: Colors.amber is
  // brightness-invariant in Flutter's Material palette, so light/dark
  // tokens intentionally match instead of diverging like the others.
  final Color starred;

  static const HalcyonTokens dark = HalcyonTokens(
    pane: Color(0xFF333333),
    dialog: Color(0xFF383838),
    surface: Color(0xFF414141),
    input: Color(0xFF262626),
    border: Color(0xFF515151),
    borderSoft: Color(0xFF454545),
    text: Color(0xFFE0E0E0),
    textDim: Color(0xFF9A9A9A),
    textFaint: Color(0xFF6F6F6F),
    accent: Color(0xFF0A84FF),
    success: Color(0xFF32D74B),
    danger: Color(0xFFFF453A),
    starred: Color(0xFFFFC107),
  );

  static const HalcyonTokens light = HalcyonTokens(
    pane: Color(0xFFF2F2F2),
    dialog: Color(0xFFFBFBFB),
    surface: Color(0xFFE9E9E9),
    input: Color(0xFFFFFFFF),
    border: Color(0xFFC9C9C9),
    borderSoft: Color(0xFFDCDCDC),
    text: Color(0xFF1E1E1E),
    textDim: Color(0xFF6B6B6B),
    textFaint: Color(0xFF9A9A9A),
    accent: Color(0xFF0066CC),
    success: Color(0xFF1B873F),
    danger: Color(0xFFC7362B),
    starred: Color(0xFFFFC107),
  );

  /// Falls back to [dark] when no extension is registered, so a widget tested
  /// in a bare MaterialApp still renders.
  static HalcyonTokens of(BuildContext context) =>
      Theme.of(context).extension<HalcyonTokens>() ?? dark;

  @override
  HalcyonTokens copyWith({
    Color? pane,
    Color? dialog,
    Color? surface,
    Color? input,
    Color? border,
    Color? borderSoft,
    Color? text,
    Color? textDim,
    Color? textFaint,
    Color? accent,
    Color? success,
    Color? danger,
    Color? starred,
  }) {
    return HalcyonTokens(
      pane: pane ?? this.pane,
      dialog: dialog ?? this.dialog,
      surface: surface ?? this.surface,
      input: input ?? this.input,
      border: border ?? this.border,
      borderSoft: borderSoft ?? this.borderSoft,
      text: text ?? this.text,
      textDim: textDim ?? this.textDim,
      textFaint: textFaint ?? this.textFaint,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      starred: starred ?? this.starred,
    );
  }

  @override
  HalcyonTokens lerp(ThemeExtension<HalcyonTokens>? other, double t) {
    if (other is! HalcyonTokens) return this;
    return HalcyonTokens(
      pane: Color.lerp(pane, other.pane, t)!,
      dialog: Color.lerp(dialog, other.dialog, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      input: Color.lerp(input, other.input, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      text: Color.lerp(text, other.text, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      starred: Color.lerp(starred, other.starred, t)!,
    );
  }
}
