import 'darkroom/darkroom_layout.dart';
import 'gallery/gallery_layout.dart';
import 'layout_theme.dart';
import 'paper/paper_layout.dart';

/// The single mapping from the persisted id to the theme implementation.
///
/// Round 4 deleted `kActiveLayoutThemeId` and the `activeLayoutTheme` getter:
/// the active theme is now `AppState.layoutThemeId`, so every reader resolves
/// it from state (`layoutThemeFor(state.layoutThemeId)`) and rebuilds when the
/// user changes it. There is deliberately no compatibility shim — a global
/// getter would silently keep serving the old constant to any caller that
/// forgot to convert.
LayoutTheme layoutThemeFor(LayoutThemeId id) => switch (id) {
  LayoutThemeId.gallery => const GalleryLayout(),
  LayoutThemeId.paper => const PaperLayout(),
  LayoutThemeId.darkroom => const DarkroomLayout(),
};
