import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/photo_item.dart';
import 'package:file_selector/file_selector.dart';
import 'batch_delete_feedback.dart';
import 'settings_dialog.dart';

class SidebarView extends StatefulWidget {
  const SidebarView({super.key});

  @override
  State<SidebarView> createState() => _SidebarViewState();
}

class _SidebarViewState extends State<SidebarView> {
  final ScrollController _scrollController = ScrollController();
  static const double _itemHeight = 48.0; // Approx height of ListTile
  String? _lastSelectedId;

  // What the list actually built this frame, accumulated by [_noteBuiltIndex]
  // and flushed once per frame. This — not the scroll offset — is the source
  // of truth for "what is on screen": ListView.builder builds exactly the
  // visible rows (plus cacheExtent), so any rebuild re-derives the range for
  // free. That's what makes the sidebar self-heal after AppState.loadFolder
  // resets the thumbnail cache (recycle/delete/copy/move all reload the
  // folder); the old scroll-listener model only re-requested when the user
  // happened to scroll, which is why thumbnails stayed blank until then.
  int _minBuiltIndex = -1;
  int _maxBuiltIndex = -1;
  bool _sweepScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureSelectedVisible(context.read<AppState>());
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _noteBuiltIndex(int index) {
    if (_minBuiltIndex == -1 || index < _minBuiltIndex) _minBuiltIndex = index;
    if (index > _maxBuiltIndex) _maxBuiltIndex = index;
    if (_sweepScheduled) return;
    _sweepScheduled = true;
    // Requesting during build would notifyListeners mid-build; defer to the
    // end of the frame, where the range is also complete.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sweepScheduled = false;
      final first = _minBuiltIndex;
      final last = _maxBuiltIndex;
      _minBuiltIndex = -1;
      _maxBuiltIndex = -1;
      if (!mounted || first == -1) return;
      // The controller expands this by its own prefetch margin and fetches
      // the visible rows first; an unchanged range is a no-op there, so
      // reporting every frame costs nothing.
      context.read<AppState>().preloadThumbnails(first, last);
    });
  }

  void _ensureSelectedVisible(AppState state) {
    if (state.selectedItemID == null || state.items.isEmpty) return;
    if (!_scrollController.hasClients) return;

    final idx = state.items.indexWhere((i) => i.id == state.selectedItemID);
    if (idx == -1) return;

    final itemTop = idx * _itemHeight;
    final itemBottom = itemTop + _itemHeight;
    final viewportOffset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;

    if (itemTop < viewportOffset) {
      // Item is above the viewport, scroll up
      _scrollController.animateTo(
        itemTop,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    } else if (itemBottom > viewportOffset + viewportHeight) {
      // Item is below the viewport, scroll down
      _scrollController.animateTo(
        itemBottom - viewportHeight,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.selectedItemID != _lastSelectedId) {
      _lastSelectedId = state.selectedItemID;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSelectedVisible(state);
      });
    }

    // Material, not a plain Container: it's the nearest Material ancestor for
    // the rows below, so ListTile's own background and ink paint normally
    // instead of being hidden behind a ColoredBox (framework assertion).
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Column(
        children: [
          Container(
            color: Theme.of(
              context,
            ).colorScheme.surface, // Action Area background
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    "Photos (${state.items.length})",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : const Color.fromARGB(255, 32, 32, 32),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _buildTopActions(context),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              child: ListView.builder(
                controller: _scrollController,
                itemCount: state.items.length,
                itemBuilder: (context, index) {
                  _noteBuiltIndex(index);
                  final item = state.items[index];
                  final isSelected = item.id == state.selectedItemID;

                  return SizedBox(
                    height: _itemHeight,
                    child: ListTile(
                      dense: true,
                      minVerticalPadding: 0,
                      // Painted by the tile itself rather than a wrapping
                      // ColoredBox, which would hide the tile's own background
                      // and ink splashes (framework assertion).
                      selectedTileColor: const Color.fromRGBO(
                        128,
                        128,
                        128,
                        0.15,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      selected: isSelected,
                      title: Text(
                        item.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13, // Smaller font size
                          color: isSelected
                              ? (Theme.of(context).brightness == Brightness.dark
                                    ? Colors.white
                                    : const Color.fromARGB(255, 59, 59, 59))
                              : Theme.of(context).colorScheme.onSurface,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildStatusIcon(item.status, state.recycleMode),
                          if (item.status != PhotoStatus.unmarked)
                            const SizedBox(width: 8),
                          _buildListThumbnail(state, item.id),
                        ],
                      ),
                      onTap: () {
                        context.read<AppState>().selectItem(item.id);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(PhotoStatus status, bool recycleMode) {
    switch (status) {
      case PhotoStatus.starred:
        return const Icon(Icons.star, color: Colors.amber, size: 16);
      case PhotoStatus.trashed:
        return Icon(
          recycleMode ? Icons.restore_from_trash : Icons.delete,
          color: Colors.red,
          size: 16,
        );
      case PhotoStatus.unmarked:
        return const SizedBox.shrink();
    }
  }

  Widget _buildListThumbnail(AppState state, String id) {
    final thumbBytes = state.getThumbnailBytes(id);
    if (thumbBytes == null) {
      return Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.memory(
        thumbBytes,
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }

  Widget _buildTopActions(BuildContext context) {
    final iconColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : const Color.fromARGB(255, 59, 59, 59);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(Icons.folder_open, size: 20, color: iconColor),
          tooltip: 'Open Folder',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => context.read<AppState>().openFolder(),
        ),
        const SizedBox(width: 12),
        _buildActionMenu(context),
      ],
    );
  }

  Widget _buildActionMenu(BuildContext context) {
    final iconColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : const Color.fromARGB(255, 59, 59, 59);

    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, size: 20, color: iconColor),
      tooltip: 'Actions',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onSelected: (value) async {
        final state = context.read<AppState>();
        if (value == 'copy' || value == 'move') {
          final String? dest = await getDirectoryPath(
            confirmButtonText: value == 'copy' ? 'Copy Here' : 'Move Here',
          );
          if (dest != null) {
            await state.processStarred(dest, value == 'move');
          }
        } else if (value == 'delete') {
          final result = await state.deleteTrashed();
          if (!context.mounted) return;
          showBatchDeleteFeedback(context, result);
        } else if (value == 'settings') {
          showDialog(context: context, builder: (ctx) => SettingsDialog());
        }
      },
      itemBuilder: (context) {
        final state = context.read<AppState>();
        final hasStarred = state.items.any(
          (i) => i.status == PhotoStatus.starred,
        );
        final hasTrashed = state.items.any(
          (i) => i.status == PhotoStatus.trashed,
        );

        final actionTextColor = Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : const Color.fromARGB(255, 59, 59, 59);

        return [
          PopupMenuItem(
            value: 'copy',
            enabled: hasStarred,
            child: Text(
              'Copy Starred...',
              style: TextStyle(color: actionTextColor),
            ),
          ),
          PopupMenuItem(
            value: 'move',
            enabled: hasStarred,
            child: Text(
              'Move Starred...',
              style: TextStyle(color: actionTextColor),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            enabled: hasTrashed,
            child: Text(
              state.recycleMode ? 'Recycle Trashed' : 'Delete Trashed',
              style: const TextStyle(color: Colors.red),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'settings',
            child: Row(
              children: [
                Icon(Icons.settings, size: 18, color: actionTextColor),
                const SizedBox(width: 8),
                Text('Options...', style: TextStyle(color: actionTextColor)),
              ],
            ),
          ),
        ];
      },
    );
  }
}
