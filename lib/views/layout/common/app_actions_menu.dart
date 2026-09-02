import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/photo_item.dart';
import '../../../providers/app_state.dart';
import '../../batch_delete_feedback.dart';
import '../../rename_dialog/rename_dialog.dart';
import '../../settings_dialog.dart';
import '../gallery/gallery_palette.dart';

/// Menu-item value for "Open Folder".
const String kOpenFolderMenuValue = 'openFolder';

/// Shared menu-item value for "Thumbnail Starred…", referenced by
/// itemBuilder, onSelected, AND the widget test so the two ends of the
/// PopupMenuButton can never drift apart — this codebase has already shipped
/// a bug where a hardcoded value/onSelected string mismatch silently
/// disabled a menu button.
const String kThumbnailStarredMenuValue = 'thumbnailStarred';
const String kCopyMenuValue = 'copy';
const String kMoveMenuValue = 'move';
const String kDeleteMenuValue = 'delete';
const String kSettingsMenuValue = 'settings';

/// The overflow menu that floats over the photo, once per layout theme.
///
/// Behavior lives here and only here: enable/disable rules, the value ->
/// action routing, and the dialogs are all decided once, and a theme only
/// gets to choose where the menu hangs (see [PhotoActions.menu]).
///
/// The panel floats at a fixed [constraints] with [PopupMenuPosition.over],
/// so it reads as a rounded surface over the photo rather than a dropdown
/// under the glyph. The fixed 246px width is part of the gallery contract
/// (mockup frame 2: `.menu {width:246px}`).
class AppActionsMenu extends StatelessWidget {
  const AppActionsMenu({
    super.key,
    required this.iconColor,
    this.iconSize = 17,
    this.offset = Offset.zero,
  });

  final Color iconColor;
  final double iconSize;

  /// Shift applied to the panel relative to the `⋮` glyph while it floats
  /// [PopupMenuPosition.over]. [Offset.zero] preserves the behavior of the
  /// old sidebar menu; the gallery column (T6) passes `Offset(
  /// 98 - columnWidth, 0)` so the panel's left edge lands 98px from the
  /// window edge.
  final Offset offset;

  void _onSelected(BuildContext context, String value) async {
    final state = context.read<AppState>();
    if (value == kOpenFolderMenuValue) {
      await state.openFolder();
    } else if (value == kCopyMenuValue || value == kMoveMenuValue) {
      final String? dest = await getDirectoryPath(
        confirmButtonText: value == kCopyMenuValue ? 'Copy Here' : 'Move Here',
      );
      if (dest != null) {
        await state.processStarred(dest, value == kMoveMenuValue);
      }
    } else if (value == kThumbnailStarredMenuValue) {
      final String? dest = await getDirectoryPath(
        confirmButtonText: 'Export Here',
      );
      if (dest != null) {
        await state.exportStarredThumbnails(dest);
      }
    } else if (value == kDeleteMenuValue) {
      final result = await state.deleteTrashed();
      if (!context.mounted) return;
      showBatchDeleteFeedback(context, result);
    } else if (value == kRenameMenuValue) {
      showDialog(context: context, builder: (ctx) => const RenameDialog());
    } else if (value == kSettingsMenuValue) {
      showDialog(context: context, builder: (ctx) => SettingsDialog());
    }
  }

  /// The `.mrule` separator: 1px hairline, 5px above/below, inset 8px from
  /// each side (`margin:5px 8px`) — it must not run full-bleed to the panel
  /// edges, which is what a bare [PopupMenuDivider] does.
  static const PopupMenuDivider _divider = PopupMenuDivider(
    height: 11,
    indent: 8,
    endIndent: 8,
  );

  /// One `.mi` row (mockup `c1-desktop-dark.html:335-356`): fixed 32px height,
  /// 10px horizontal padding, radius 4, a 14px leading icon and a 12.5px
  /// label, with an optional right-aligned shortcut. The row's four states
  /// (rest / hover / pressed / disabled, plus the danger hue) live in
  /// [_MenuRow]; the values and the routing stay here, untouched.
  PopupMenuItem<String> _row({
    required String value,
    required IconData icon,
    required String label,
    bool enabled = true,
    bool danger = false,
    String? shortcut,
  }) {
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: kMenuRowHeight,
      padding: EdgeInsets.zero,
      child: _MenuRow(
        icon: icon,
        label: label,
        enabled: enabled,
        danger: danger,
        shortcut: shortcut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // [PopupMenuItem] wraps every row in its own [InkWell], whose default
    // splash/highlight paints on TOP of [_MenuRow]'s own hover/press well
    // (`--sunk` / `--accent-wash`), producing a visible double overlay. Row
    // state is already fully driven by [_MenuRowState] via MouseRegion /
    // Listener, so the built-in ink is pure noise here — suppressed by
    // zeroing splashColor/highlightColor for the menu's subtree only.
    return Theme(
      data: Theme.of(context).copyWith(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: PopupMenuButton<String>(
        icon: Icon(Icons.more_horiz, size: 20, color: iconColor),
        tooltip: 'Actions',
        padding: EdgeInsets.zero,
        // Float over the photo, anchored at the `⋮` glyph (mockup frame 2:
        // `.menu {position:absolute;left:98px;bottom:14px;width:246px}`),
        // shifted by the caller-supplied [offset] (default zero).
        position: PopupMenuPosition.over,
        offset: offset,
        constraints: const BoxConstraints.tightFor(width: 246),
        elevation: 24,
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        menuPadding: const EdgeInsets.all(6),
        onSelected: (value) => _onSelected(context, value),
        itemBuilder: (context) {
          final state = context.read<AppState>();
          final hasStarred = state.items.any(
            (i) => i.status == PhotoStatus.starred,
          );
          final hasTrashed = state.items.any(
            (i) => i.status == PhotoStatus.trashed,
          );

          return [
            _row(
              value: kOpenFolderMenuValue,
              icon: Icons.folder_open,
              label: 'Open Folder',
              shortcut: openFolderShortcutLabel(),
            ),
            _divider,
            _row(
              value: kCopyMenuValue,
              icon: Icons.copy_outlined,
              label: 'Copy Starred…',
              enabled: hasStarred,
            ),
            _row(
              value: kMoveMenuValue,
              icon: Icons.arrow_forward,
              label: 'Move Starred…',
              enabled: hasStarred,
            ),
            _row(
              value: kThumbnailStarredMenuValue,
              icon: Icons.image_outlined,
              label: 'Thumbnail Starred…',
              enabled: hasStarred,
            ),
            _divider,
            _row(
              value: kRenameMenuValue,
              icon: Icons.edit_outlined,
              label: 'Rename by EXIF…',
              enabled: state.items.isNotEmpty,
            ),
            _divider,
            _row(
              value: kDeleteMenuValue,
              icon: Icons.delete_outline,
              label: state.recycleMode ? 'Recycle Trashed' : 'Delete Trashed',
              enabled: hasTrashed,
              danger: true,
            ),
            _divider,
            _row(
              value: kSettingsMenuValue,
              icon: Icons.settings_outlined,
              label: 'Options…',
            ),
          ];
        },
      ),
    );
  }
}

/// How the Open Folder chord is written for the CURRENT platform: `⌘O` on
/// macOS, `Ctrl+O` everywhere else. The binding itself accepts both modifiers
/// (see GalleryDesktopSurface); only the advertised label is platform-shaped,
/// because a Windows user reading `⌘O` learns nothing.
String openFolderShortcutLabel() =>
    defaultTargetPlatform == TargetPlatform.macOS ? '⌘O' : 'Ctrl+O';

/// Fixed `.mi` row height. The mockup's whole point in fixing it is that the
/// separators land on a rhythm instead of wherever the label's own line box
/// left them, so this is a constant, not a minimum.
const double kMenuRowHeight = 32;

/// Leading glyph size (`.menu .mi svg{width:14px}`).
const double kMenuIconSize = 14;

/// Icon opacity by row state (`.menu .mi svg` and its state rules). The label
/// leads and the glyph follows: it rests at half emphasis and rises with the
/// row.
const double kMenuIconOpacityRest = 0.5;
const double kMenuIconOpacityHover = 0.95;
const double kMenuIconOpacityDisabled = 0.3;
const double kMenuIconOpacityDanger = 0.7;

/// One row of the actions menu, carrying the mockup's four states.
///
/// Flutter's [PopupMenuItem] draws its own ink overlay on hover/press; this
/// row paints the mockup's own well (`--sunk` on hover, `--accent-wash` on
/// press) underneath it, which is what makes hover read on the whole item
/// rather than on its background alone.
class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.danger,
    this.shortcut,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool danger;
  final String? shortcut;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = GalleryPalette.of(context);
    // A disabled row is inert: no hover well, no icon lift, no pointer.
    final hovered = _hovered && widget.enabled;
    final pressed = _pressed && widget.enabled;

    final Color labelColor;
    final double iconOpacity;
    if (!widget.enabled) {
      labelColor = palette.textFaint; // --ink-faint
      iconOpacity = kMenuIconOpacityDisabled;
    } else if (widget.danger) {
      // Danger keeps its hue at rest and gains no fill on hover; the colour is
      // the warning, a red row would be a second one saying the same thing.
      labelColor = colors.error;
      iconOpacity = hovered ? 1 : kMenuIconOpacityDanger;
    } else {
      labelColor = colors.onSurface; // --ink
      iconOpacity = hovered ? kMenuIconOpacityHover : kMenuIconOpacityRest;
    }

    final Color background;
    if (pressed) {
      background = colors.primary.withValues(alpha: 0.18); // --accent-wash
    } else if (hovered) {
      background = colors.surfaceContainer; // --sunk
    } else {
      background = Colors.transparent;
    }

    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic, // `.mi.dim{cursor:default}`
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: Container(
          height: kMenuRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: kMenuIconSize,
                color: labelColor.withValues(alpha: iconOpacity),
              ),
              const SizedBox(width: 11), // `.mi{gap:11px}`
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    letterSpacing: 0.01 * 12.5,
                    color: labelColor,
                  ),
                ),
              ),
              if (widget.shortcut != null)
                Text(
                  widget.shortcut!,
                  style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 0.06 * 10.5,
                    color: palette.textFaint,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
