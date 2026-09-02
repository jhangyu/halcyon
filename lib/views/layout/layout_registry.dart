import 'gallery/gallery_layout.dart';
import 'layout_theme.dart';

/// Round 1: a constant. Round 3 replaces this with the persisted setting;
/// nothing else changes.
const LayoutThemeId kActiveLayoutThemeId = LayoutThemeId.gallery;

LayoutTheme layoutThemeFor(LayoutThemeId id) => switch (id) {
  LayoutThemeId.gallery => const GalleryLayout(),
};

LayoutTheme get activeLayoutTheme => layoutThemeFor(kActiveLayoutThemeId);
