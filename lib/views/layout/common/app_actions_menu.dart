import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/photo_item.dart';
import '../../../providers/app_state.dart';
import '../../batch_delete_feedback.dart';
import '../../rename_dialog/rename_dialog.dart';
import '../../settings_dialog.dart';
import '../../theme_tokens.dart';

/// Menu-item value for "Open Folder".
const String kOpenFolderMenuValue = 'openFolder';

/// Shared menu-item value for "Thumbnail Starred...", referenced by
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

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
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

        // Item metrics per the gallery mockup frame 2 (`.menu .mi`): a 15px
        // leading icon at 75% opacity, 8h/10v padding, radius 4, 12.5px label.
        final leadingIconColor = iconColor.withValues(alpha: 0.75);

        return [
          PopupMenuItem(
            value: kOpenFolderMenuValue,
            child: Row(
              children: [
                Icon(Icons.folder_open, size: iconSize, color: leadingIconColor),
                const SizedBox(width: 8),
                Text('Open Folder', style: TextStyle(color: iconColor)),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: kCopyMenuValue,
            enabled: hasStarred,
            child: Text(
              'Copy Starred...',
              style: TextStyle(color: iconColor),
            ),
          ),
          PopupMenuItem(
            value: kMoveMenuValue,
            enabled: hasStarred,
            child: Text(
              'Move Starred...',
              style: TextStyle(color: iconColor),
            ),
          ),
          PopupMenuItem(
            value: kThumbnailStarredMenuValue,
            enabled: hasStarred,
            child: Text(
              'Thumbnail Starred...',
              style: TextStyle(color: iconColor),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: kRenameMenuValue,
            enabled: state.items.isNotEmpty,
            child: Text(
              'Rename by EXIF...',
              style: TextStyle(color: iconColor),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: kDeleteMenuValue,
            enabled: hasTrashed,
            child: Text(
              state.recycleMode ? 'Recycle Trashed' : 'Delete Trashed',
              style: TextStyle(color: HalcyonTokens.of(context).danger),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: kSettingsMenuValue,
            child: Row(
              children: [
                Icon(Icons.settings, size: 18, color: leadingIconColor),
                const SizedBox(width: 8),
                Text('Options...', style: TextStyle(color: iconColor)),
              ],
            ),
          ),
        ];
      },
    );
  }
}