import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/photo_item.dart';
import '../providers/app_state.dart';

/// Floating star/trash bar over the detail view.
///
/// The delete button doubles as the recycle-mode indicator: in recycle mode
/// it becomes a trash can with an up-arrow (files are retrievable from
/// `.trash`). Red is reused for both modes because amber belongs to the star
/// button — the modes differ by icon shape, not colour. Right-click toggles
/// the mode; left-click keeps its usual "mark this photo" meaning.
class PhotoActionBar extends StatelessWidget {
  const PhotoActionBar({super.key, required this.item});

  final PhotoItem item;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isStarred = item.status == PhotoStatus.starred;
    final isTrashed = item.status == PhotoStatus.trashed;
    final recycle = state.recycleMode;

    final IconData deleteIcon = recycle
        ? (isTrashed
              ? Icons.restore_from_trash
              : Icons.restore_from_trash_outlined)
        : (isTrashed ? Icons.delete : Icons.delete_outline);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              isStarred ? Icons.star : Icons.star_border,
              color: isStarred ? Colors.amber : null,
            ),
            onPressed: () =>
                context.read<AppState>().markCurrent(PhotoStatus.starred),
            tooltip: 'Star (S)',
          ),
          const SizedBox(width: 20),
          GestureDetector(
            onSecondaryTap: () => context.read<AppState>().toggleRecycleMode(),
            child: IconButton(
              icon: Icon(deleteIcon, color: isTrashed ? Colors.red : null),
              onPressed: () =>
                  context.read<AppState>().markCurrent(PhotoStatus.trashed),
              tooltip: recycle
                  ? 'Recycle (X) — right-click: switch to direct delete'
                  : 'Trash (X) — right-click: switch to recycle mode',
            ),
          ),
        ],
      ),
    );
  }
}
