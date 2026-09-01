import 'package:flutter/material.dart';
import 'main_surface.dart';

/// One case per shipped theme. Deleting a theme = delete its directory and
/// delete its case here; `layoutThemeFor`'s exhaustive switch turns any
/// leftover reference into a compile error.
enum LayoutThemeId { gallery }

abstract class LayoutTheme {
  const LayoutTheme();

  LayoutThemeId get id;

  /// The theme owns the whole palette, for both brightnesses, including the
  /// theme extensions it registers.
  ThemeData themeDataFor(Brightness brightness);

  /// Arrangement and paint only. Every behaviour this needs is already
  /// resolved inside [surface].
  Widget buildMainSurface(BuildContext context, MainSurface surface);
}