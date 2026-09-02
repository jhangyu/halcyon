import 'package:flutter/material.dart';

import '../layout_theme.dart';
import '../main_surface.dart';
import 'darkroom_desktop.dart';
import 'darkroom_mobile.dart';
import 'darkroom_palette.dart';

/// The `darkroom` layout theme (round 2, task #13).
///
/// Same shape as `GalleryLayout` — see `layout_theme.dart` — so registration
/// (task #14) is a one-line addition to `LayoutThemeId` and
/// `layout_registry.dart`'s switch. This file does not touch either; it is
/// buildable and testable standalone by constructing it directly.
class DarkroomLayout extends LayoutTheme {
  const DarkroomLayout();

  @override
  LayoutThemeId get id => LayoutThemeId.darkroom;

  @override
  ThemeData themeDataFor(Brightness brightness) => darkroomThemeData(brightness);

  @override
  Widget buildMainSurface(BuildContext context, MainSurface surface) =>
      DarkroomDesktopSurface(surface: surface);

  @override
  Widget buildMobileSurface(BuildContext context, MainSurface surface) =>
      DarkroomMobileSurface(surface: surface);
}
