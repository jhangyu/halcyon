import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../layout/layout_registry.dart';
import '../layout/layout_theme.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// The Appearance tab (frozen spec `docs/logs/2026-09-02/theme-switcher-spec.md`,
/// design `mockup/theme-switcher/candidate-3.html` "List and stage").
///
/// Stateful, unlike its sibling tabs: the stage previews the layout under the
/// pointer, and the reset confirm is inline. Both are transient view state and
/// must never reach [AppState] — hovering a row is not choosing it (spec §4),
/// and a hover that persisted would be revert-on-dismiss's problem forever.
/// The reset confirm's body text, user-approved 2026-09-02 (superseding the
/// frozen spec section 2.2 wording). Exported as a constant so the widget and
/// its test assert the SAME string — a test that retyped it would pass while
/// the shipped copy drifted.
const String kResetConfirmCopy =
    'This resets every Halcyon preference — appearance and layout theme, '
    'auto-advance, overwrite-on-export, decode concurrency, export '
    'quality/long-edge/format, memory retention tier, and keyboard '
    'shortcuts. Photo folders and their star/trash marks are not touched. '
    'This cannot be undone. Reset applies at once and closes Settings.';

class AppearanceTab extends StatefulWidget {
  const AppearanceTab({super.key});

  @override
  State<AppearanceTab> createState() => _AppearanceTabState();
}

class _AppearanceTabState extends State<AppearanceTab> {
  /// Non-null only while the pointer rests on a layout row it has not chosen.
  LayoutThemeId? _hovered;
  bool _confirmingReset = false;

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();
    final brightness = _resolvedBrightness(context, state.themeMode);
    final stageId = _hovered ?? state.layoutThemeId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Appearance'),
        settingsBlock(
          t,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fixed 216 / gap 16 / Expanded 424 — the content column is 656
              // (920 dialog - 224 rail - 2x20 padding), spec §2.1.
              SizedBox(width: 216, child: _leftColumn(t, state, brightness)),
              const SizedBox(width: 16),
              Expanded(child: _stage(t, state, stageId, brightness)),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _resetSection(t),
      ],
    );
  }

  /// `System` is an intent, not a rendering: the stage and the tag bar have to
  /// know which of the two palettes the user will actually get.
  Brightness _resolvedBrightness(BuildContext context, ThemeMode mode) =>
      switch (mode) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system => MediaQuery.platformBrightnessOf(context),
      };

  // --- left column: mode control, then the layout list ---

  Widget _leftColumn(HalcyonTokens t, AppState state, Brightness brightness) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subLabel(t, 'Mode'),
        Row(
          children: [
            Expanded(child: _modeCell(t, state, ThemeMode.dark, 'Dark')),
            const SizedBox(width: 5),
            Expanded(child: _modeCell(t, state, ThemeMode.light, 'Light')),
            const SizedBox(width: 5),
            Expanded(child: _modeCell(t, state, ThemeMode.system, 'System')),
          ],
        ),
        // Required by spec §2.1.3: "System" alone does not tell the user which
        // rendering they get, so the resolved value is printed under it.
        if (state.themeMode == ThemeMode.system)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'macOS · currently '
              '${brightness == Brightness.dark ? 'dark' : 'light'}',
              key: const Key('appearance.systemBrightnessNote'),
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                color: t.textDim,
              ),
            ),
          ),
        const SizedBox(height: 14),
        _subLabel(t, 'Layout'),
        for (final id in LayoutThemeId.values) ...[
          if (id != LayoutThemeId.values.first) const SizedBox(height: 6),
          _layoutRow(t, state, id, brightness),
        ],
      ],
    );
  }

  /// A section label's text run WITHOUT the trailing hairline: this sits
  /// inside a block, where the hairline would read as a divider (spec §2.1.1).
  Widget _subLabel(HalcyonTokens t, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.63,
          color: t.textFaint,
        ),
      ),
    );
  }

  Widget _modeCell(
    HalcyonTokens t,
    AppState state,
    ThemeMode mode,
    String label,
  ) {
    final selected = state.themeMode == mode;
    return _selectable(
      t,
      key: Key('appearance.mode.${mode.name}'),
      selected: selected,
      onTap: () => context.read<AppState>().setThemeMode(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: t.text),
        ),
      ),
    );
  }

  Widget _layoutRow(
    HalcyonTokens t,
    AppState state,
    LayoutThemeId id,
    Brightness brightness,
  ) {
    final selected = state.layoutThemeId == id;
    return MouseRegion(
      // Hover is preview only — it never reaches AppState and never persists.
      onEnter: (_) => setState(() => _hovered = id),
      onExit: (_) => setState(() {
        if (_hovered == id) _hovered = null;
      }),
      child: _selectable(
        t,
        key: Key('appearance.layout.${id.name}'),
        selected: selected,
        onTap: () => context.read<AppState>().setLayoutThemeId(id),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Row(
            children: [
              _ThemeMiniature(
                id: id,
                brightness: brightness,
                width: 64,
                height: 38,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _themeName(id),
                  style: TextStyle(fontSize: 12, color: t.text),
                ),
              ),
              _radio(t, selected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _radio(HalcyonTokens t, bool selected) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? t.accent : null,
        border: Border.all(color: selected ? t.accent : t.border),
      ),
      child: selected
          ? const Icon(Icons.check, size: 10, color: Colors.white)
          : null,
    );
  }

  /// The ONE selection treatment in this feature, copied from the retention
  /// tier card (performance_memory_tab.dart `_tierCard`): no fill unselected,
  /// an 18%-alpha accent fill plus an accent border when selected. Spec §3
  /// forbids inventing a second one.
  Widget _selectable(
    HalcyonTokens t, {
    required Key key,
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Material(
      key: key,
      color: selected ? t.accent.withValues(alpha: 0.18) : null,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: selected ? t.accent : t.borderSoft),
            borderRadius: BorderRadius.circular(5),
          ),
          child: child,
        ),
      ),
    );
  }

  // --- right column: the stage ---

  Widget _stage(
    HalcyonTokens t,
    AppState state,
    LayoutThemeId stageId,
    Brightness brightness,
  ) {
    final previewOnly = _hovered != null && _hovered != state.layoutThemeId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            key: const Key('appearance.stage'),
            height: 196,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: t.borderSoft),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _ThemeMiniature(id: stageId, brightness: brightness),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    height: 20,
                    width: double.infinity,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    color: const Color(0x6B000000), // rgba(0,0,0,.42)
                    child: Text(
                      _tagBarText(stageId, brightness, previewOnly),
                      key: const Key('appearance.stage.tag'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9,
                        letterSpacing: 0.81, // 0.09em at 9px
                        color: Color(0xFFEDEBE7),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 9),
        RichText(
          key: const Key('appearance.stage.caption'),
          text: TextSpan(
            style: TextStyle(fontSize: 11, color: t.textDim, height: 1.5),
            children: [
              TextSpan(
                text: '${_themeName(stageId)}. ',
                style: TextStyle(
                  color: t.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(text: '${_themeBlurb(stageId)} '),
              TextSpan(
                text: previewOnly
                    ? 'Previewing on hover; click the row to keep it.'
                    : 'Hover another layout to preview it here.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// `<Theme> · <Mode> · <bg hex> <role> · <accent hex> accent`, plus
  /// ` · preview only` when the stage is showing a hover (spec §2.1 right
  /// column, item 2). `<Mode>` is the RESOLVED brightness, not the stored
  /// intent — mockup frame 3 shows "Paper · Light" while Mode is System.
  String _tagBarText(
    LayoutThemeId id,
    Brightness brightness,
    bool previewOnly,
  ) {
    final theme = layoutThemeFor(id).themeDataFor(brightness);
    final bg = _hex(theme.scaffoldBackgroundColor);
    final accent = _hex(theme.colorScheme.primary);
    final mode = brightness == Brightness.dark ? 'Dark' : 'Light';
    final tail = previewOnly ? ' · preview only' : '';
    return '${_themeName(id)} · $mode · $bg ${_bgRole(id)} · $accent accent'
        '$tail';
  }

  // --- reset ---

  Widget _resetSection(HalcyonTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _resetLabelRow(t),
        settingsBlock(
          t,
          _confirmingReset ? _resetConfirm(t) : _resetResting(t),
        ),
      ],
    );
  }

  /// `settingsSectionLabel` with a trailing button on the label row, the same
  /// placement `Use detected default` uses — but in danger colours, so it does
  /// not read as one more ordinary control (spec §2.2).
  Widget _resetLabelRow(HalcyonTokens t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            'RESET',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.63,
              color: t.textFaint,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: t.borderSoft)),
          Material(
            key: const Key('appearance.resetAll'),
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => setState(() => _confirmingReset = true),
              borderRadius: BorderRadius.circular(5),
              child: Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: t.danger),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  'Reset all settings…',
                  style: TextStyle(fontSize: 11, color: t.danger),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resetResting(HalcyonTokens t) {
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 11, color: t.textDim, height: 1.55),
        children: [
          const TextSpan(text: 'Restores '),
          TextSpan(
            text: 'every',
            style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
          ),
          const TextSpan(
            text: ' Halcyon preference across all four tabs, not just this '
                'one. Star and trash marks live in each photo folder’s '
                'own status file and are not affected.',
          ),
        ],
      ),
    );
  }

  Widget _resetConfirm(HalcyonTokens t) {
    return Container(
      key: const Key('appearance.resetConfirm'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.10),
        border: Border.all(color: t.danger),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // USER RULING 2026-09-02, superseding the frozen spec section 2.2
          // confirm text. The frozen copy enumerated "recycle mode, sidebar
          // width and the folder Halcyon reopens on launch", none of which is
          // a persisted preference in this codebase — a destructive-action
          // confirm must not name settings it does not clear. This
          // replacement is the honest enumeration, approved by the user and
          // relayed through team-lead. Copy only; the confirm -> clear ->
          // apply defaults -> committed -> pop ordering is unchanged.
          Text(
            kResetConfirmCopy,
            key: const Key('appearance.resetConfirmCopy'),
            style: TextStyle(fontSize: 11, color: t.text, height: 1.55),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              settingsSmallButton(
                t,
                'Keep settings',
                () => setState(() => _confirmingReset = false),
                key: const Key('appearance.resetKeep'),
              ),
              const SizedBox(width: 8),
              Material(
                key: const Key('appearance.resetConfirmButton'),
                color: t.danger,
                borderRadius: BorderRadius.circular(5),
                child: InkWell(
                  onTap: _performReset,
                  borderRadius: BorderRadius.circular(5),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: const Text(
                      'Reset everything',
                      style: TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Order matters and is the whole point (spec §7): reset, then tell the
  /// dialog it is committed, THEN pop. Popping first — or popping without the
  /// committed flag — lets the dialog's revert-on-dismiss snapshot restore the
  /// pre-reset values, silently undoing the reset the user just confirmed.
  void _performReset() {
    context.read<AppState>().resetAllSettings();
    SettingsResetScope.of(context)?.markCommitted();
    Navigator.of(context).maybePop();
  }

  static String _themeName(LayoutThemeId id) => switch (id) {
    LayoutThemeId.gallery => 'Gallery',
    LayoutThemeId.paper => 'Paper',
    LayoutThemeId.darkroom => 'Darkroom',
  };

  /// The name each theme's own palette file gives its background token, so the
  /// tag bar reads as that theme's vocabulary rather than a generic "bg".
  static String _bgRole(LayoutThemeId id) => switch (id) {
    LayoutThemeId.gallery => 'canvas',
    LayoutThemeId.paper => 'app',
    LayoutThemeId.darkroom => 'ground',
  };

  static String _themeBlurb(LayoutThemeId id) => switch (id) {
    LayoutThemeId.gallery =>
      'All chrome sits in one narrow column in the side gutter; the '
          'photograph keeps full window height and is never overlapped.',
    LayoutThemeId.paper =>
      'The print rests on a warm mount with the filmstrip floating beneath '
          'it on translucent glass.',
    LayoutThemeId.darkroom =>
      'The print is centred on a wide, deliberately dim surround with a '
          'single rail of frames beneath it.',
  };

  static String _hex(Color c) {
    final v =
        ((c.a * 255).round() << 24) |
        ((c.r * 255).round() << 16) |
        ((c.g * 255).round() << 8) |
        (c.b * 255).round();
    return '#${(v & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}';
  }
}

/// Lets the Appearance tab tell the enclosing [SettingsDialog] that a reset
/// has been applied, so its revert-on-dismiss snapshot must NOT run.
///
/// An InheritedWidget rather than a callback threaded through the tab switch:
/// the tabs are built by a `switch` that constructs them const, and reset is
/// the single exception to the dialog's revert contract — making that
/// exception explicit and named is better than widening every tab's
/// constructor for it.
class SettingsResetScope extends InheritedWidget {
  const SettingsResetScope({
    super.key,
    required this.markCommitted,
    required super.child,
  });

  final VoidCallback markCommitted;

  static SettingsResetScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsResetScope>();

  @override
  bool updateShouldNotify(SettingsResetScope oldWidget) => false;
}

/// A schematic of one layout theme, drawn from that theme's real palette.
///
/// Percentage-based like the mockup's `.m` block, so the same construction
/// draws the 64x38 list thumbnail and the 424x196 stage without a second set
/// of numbers. It deliberately does NOT build the real layout widgets and does
/// not decode an image (spec §4): a preview that mounted the real surface
/// would need a photo, a scroll controller and an AppState of its own.
class _ThemeMiniature extends StatelessWidget {
  const _ThemeMiniature({
    required this.id,
    required this.brightness,
    this.width,
    this.height,
  });

  final LayoutThemeId id;
  final Brightness brightness;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = layoutThemeFor(id).themeDataFor(brightness);
    final child = LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: switch (id) {
            LayoutThemeId.gallery => _gallery(theme, w, h),
            LayoutThemeId.paper => _paper(theme, w, h),
            LayoutThemeId.darkroom => _darkroom(theme, w, h),
          },
        );
      },
    );
    return SizedBox(
      width: width,
      height: height,
      child: ClipRect(
        child: ColoredBox(color: theme.scaffoldBackgroundColor, child: child),
      ),
    );
  }

  /// Stand-in for a photograph. A gradient, not an image: the stage must not
  /// decode anything.
  static Widget _print(ThemeData theme, {required Rect rect}) {
    return Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.55),
              theme.colorScheme.surfaceContainerHighest,
              theme.colorScheme.onSurface.withValues(alpha: 0.45),
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }

  // Gallery: a 14%-wide gutter of chips on the left, photo filling the rest,
  // wall label bottom-right.
  static List<Widget> _gallery(ThemeData theme, double w, double h) {
    final colors = theme.colorScheme;
    return [
      _print(theme, rect: Rect.fromLTWH(w * 0.14, 0, w * 0.86, h)),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: w * 0.14,
        child: ColoredBox(color: colors.surface),
      ),
      for (var i = 0; i < 5; i++)
        Positioned(
          left: w * 0.02,
          top: h * (0.06 + i * 0.13),
          width: w * 0.10,
          height: h * 0.11,
          child: ColoredBox(color: colors.surfaceContainerHighest),
        ),
      Positioned(
        right: w * 0.04,
        bottom: h * 0.14,
        width: w * 0.26,
        height: h * 0.035,
        child: const ColoredBox(color: Color(0xA8FFFFFF)),
      ),
      Positioned(
        right: w * 0.04,
        bottom: h * 0.08,
        width: w * 0.34,
        height: h * 0.025,
        child: const ColoredBox(color: Color(0x66FFFFFF)),
      ),
    ];
  }

  // Paper: the print on a warm mount, filmstrip floating beneath it.
  static List<Widget> _paper(ThemeData theme, double w, double h) {
    final colors = theme.colorScheme;
    return [
      _print(
        theme,
        rect: Rect.fromLTWH(w * 0.10, h * 0.09, w * 0.80, h * 0.61),
      ),
      Positioned(
        left: w * 0.10,
        right: w * 0.10,
        bottom: h * 0.09,
        height: h * 0.15,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 5; i++)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: w * 0.008),
                  child: SizedBox(
                    width: w * 0.104,
                    height: h * 0.096,
                    child: ColoredBox(
                      color: colors.surfaceContainerHighest,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  // Darkroom: a narrow centred print on a wide dim surround, one rail below.
  static List<Widget> _darkroom(ThemeData theme, double w, double h) {
    final colors = theme.colorScheme;
    return [
      _print(
        theme,
        rect: Rect.fromLTWH(w * 0.21, h * 0.08, w * 0.58, h * 0.66),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: h * 0.19,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 7; i++)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: w * 0.008),
                child: SizedBox(
                  width: w * 0.09,
                  height: h * 0.106,
                  child: ColoredBox(color: colors.surfaceContainerHighest),
                ),
              ),
          ],
        ),
      ),
    ];
  }
}
