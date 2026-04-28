import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/photo_item.dart';
import 'package:file_selector/file_selector.dart';
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

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Initial load after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _onScroll();
        _ensureSelectedVisible(context.read<AppState>());
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final state = context.read<AppState>();
    if (state.items.isEmpty) return;

    if (!_scrollController.hasClients) return;

    final double scrollOffset = _scrollController.offset;
    final double viewportHeight = _scrollController.position.viewportDimension;

    final int firstVisibleIdx = (scrollOffset / _itemHeight).floor();
    final int lastVisibleIdx = ((scrollOffset + viewportHeight) / _itemHeight)
        .ceil();

    // Request thumbnails for visible +/- 20
    state.preloadThumbnails(firstVisibleIdx - 20, lastVisibleIdx + 20);
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

    return Container(
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
                  final item = state.items[index];
                  final isSelected = item.id == state.selectedItemID;

                  return Container(
                    height: _itemHeight,
                    alignment: Alignment.center,
                    color: isSelected
                        ? const Color.fromRGBO(
                            128,
                            128,
                            128,
                            0.15,
                          ) // Slightly darker for better visibility
                        : Colors.transparent,
                    child: ListTile(
                      dense: true,
                      minVerticalPadding: 0,
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
                          _buildStatusIcon(item.status),
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

  Widget _buildStatusIcon(PhotoStatus status) {
    switch (status) {
      case PhotoStatus.starred:
        return const Icon(Icons.star, color: Colors.amber, size: 16);
      case PhotoStatus.trashed:
        return const Icon(Icons.delete, color: Colors.red, size: 16);
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
          await state.deleteTrashed();
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
            child: const Text(
              'Delete Trashed',
              style: TextStyle(color: Colors.red),
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
