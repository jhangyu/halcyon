import 'package:flutter/material.dart';

import '../layout_theme.dart';
import '../main_surface.dart';
import 'paper_desktop.dart';
import 'paper_mobile.dart';
import 'paper_palette.dart';

/// The `paper` layout theme (round 2, task #12).
///
/// NOTE: `LayoutThemeId.paper` does not exist yet on the shared
/// `layout_theme.dart` enum (owned by task #14's registry wiring). This file
/// will not pass `flutter analyze` until that case is added — expected and
/// flagged to team-lead; see the round-2 handoff message. Everything else in
/// this theme (palette, desktop arrangement, welcome screen) is independently
/// buildable and tested without this class.
class PaperLayout extends LayoutTheme {
  const PaperLayout();

  @override
  LayoutThemeId get id => LayoutThemeId.paper;

  @override
  ThemeData themeDataFor(Brightness brightness) => paperThemeData(brightness);

  @override
  Widget buildMainSurface(BuildContext context, MainSurface surface) =>
      PaperDesktopSurface(surface: surface);

  /// Round 3 (task #16): the mobile arrangement (mockup frame 1 + frame 4).
  /// See `paper_mobile.dart` for what is and is not in scope this round.
  @override
  Widget buildMobileSurface(BuildContext context, MainSurface surface) =>
      PaperMobileSurface(surface: surface);
}
