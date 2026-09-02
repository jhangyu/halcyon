import 'package:flutter/material.dart';

import '../layout_theme.dart';
import '../main_surface.dart';
import 'gallery_desktop.dart';
import 'gallery_palette.dart';

/// The `gallery` layout theme (T9 of the gallery layout plan).
class GalleryLayout extends LayoutTheme {
  const GalleryLayout();

  @override
  LayoutThemeId get id => LayoutThemeId.gallery;

  @override
  ThemeData themeDataFor(Brightness brightness) => galleryThemeData(brightness);

  @override
  Widget buildMainSurface(BuildContext context, MainSurface surface) =>
      GalleryDesktopSurface(surface: surface);
}
