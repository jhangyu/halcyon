import 'darkroom/darkroom_layout.dart';
import 'gallery/gallery_layout.dart';
import 'layout_theme.dart';
import 'paper/paper_layout.dart';

/// Round 1: a constant. Round 3 replaces this with the persisted setting;
/// nothing else changes.
const LayoutThemeId kActiveLayoutThemeId = LayoutThemeId.gallery;

LayoutTheme layoutThemeFor(LayoutThemeId id) => switch (id) {
  LayoutThemeId.gallery => const GalleryLayout(),
  LayoutThemeId.paper => const PaperLayout(),
  LayoutThemeId.darkroom => const DarkroomLayout(),
};

LayoutTheme get activeLayoutTheme => layoutThemeFor(kActiveLayoutThemeId);
