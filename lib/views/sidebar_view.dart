import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/photo_item.dart';
import '../services/image_pipeline/photo_payload.dart';
import '../services/image_pipeline/raw_pixels_image.dart';
import 'theme_tokens.dart';
import 'layout/common/app_actions_menu.dart';

// The overflow menu lives in `layout/common/app_actions_menu.dart` (T4
// extraction); the constants live next to the widget that builds them and are
// re-exported here so the widget test and existing callers keep importing from
// one place.
export 'layout/common/app_actions_menu.dart'
    show kThumbnailStarredMenuValue, kCopyMenuValue, kMoveMenuValue,
        kDeleteMenuValue, kSettingsMenuValue;

class SidebarView extends StatefulWidget {
  const SidebarView({super.key});

  @override
  State<SidebarView> createState() => _SidebarViewState();
}

class _SidebarViewState extends State<SidebarView> {
  final ScrollController _scrollController = ScrollController();
  static const double _itemHeight = 48.0; // Approx height of ListTile
  String? _lastSelectedId;

  // itemBuilder running is the TRIGGER to re-report what's on screen (it runs
  // on any rebuild, so every path that resets the thumbnail cache —
  // recycle/delete/copy/move all reload the folder — self-heals without its
  // own call site; the old scroll-listener model only re-requested when the
  // user happened to scroll, so those paths came back blank).
  //
  // The trigger is NOT the range: while scrolling, ListView.builder builds
  // only the rows that just came into range and reuses the rest, so the
  // indices seen in one frame can be a single leading-edge row. Reporting
  // that as the visible range made the controller trim its cache around one
  // row and evict thumbnails still on screen at the far edge, which is what
  // the flicker was. The range comes from viewport geometry instead — exact,
  // because itemExtent pins every row to _itemHeight.
  bool _sweepScheduled = false;
  int _fallbackFirstIndex = -1;
  int _fallbackLastIndex = -1;

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

  // Shared light-mode color for icons/selected-row text; dark mode always
  // uses plain white. Kept separate from the header title's 32,32,32 below —
  // that one is intentionally a different shade and unification is an
  // undecided product call, not a bug.
  Color _iconColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? HalcyonTokens.of(context).text
      : const Color.fromARGB(255, 59, 59, 59);

  void _noteBuiltIndex(int index) {
    // Only used before the list has a scroll position (first frame).
    if (_fallbackFirstIndex == -1 || index < _fallbackFirstIndex) {
      _fallbackFirstIndex = index;
    }
    if (index > _fallbackLastIndex) _fallbackLastIndex = index;
    if (_sweepScheduled) return;
    _sweepScheduled = true;
    // Requesting during build would notifyListeners mid-build; defer to the
    // end of the frame, where layout is also settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sweepScheduled = false;
      final first = _fallbackFirstIndex;
      final last = _fallbackLastIndex;
      _fallbackFirstIndex = -1;
      _fallbackLastIndex = -1;
      if (!mounted) return;
      // The controller expands this by its own prefetch margin and fetches
      // the visible rows first; an unchanged range is a no-op there, so
      // reporting every frame costs nothing.
      final state = context.read<AppState>();
      if (!_scrollController.hasClients) {
        if (first != -1) state.preloadThumbnails(first, last);
        return;
      }
      final offset = _scrollController.offset;
      final viewportHeight = _scrollController.position.viewportDimension;
      state.preloadThumbnails(
        (offset / _itemHeight).floor(),
        ((offset + viewportHeight) / _itemHeight).ceil(),
      );
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
                      // Intentionally 32,32,32, not the 59,59,59 used
                      // elsewhere via _iconColor — unifying is an undecided
                      // product call, left as-is.
                      color: Theme.of(context).brightness == Brightness.dark
                          ? HalcyonTokens.of(context).text
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
                // Makes _itemHeight a fact rather than an approximation: both
                // the visible-range math above and _ensureSelectedVisible
                // below compute row positions from it.
                itemExtent: _itemHeight,
                itemCount: state.items.length,
                itemBuilder: (context, index) {
                  _noteBuiltIndex(index);
                  final item = state.items[index];
                  final isSelected = item.id == state.selectedItemID;

                  return ListTile(
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    selected: isSelected,
                    title: Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13, // Smaller font size
                        color: isSelected
                            ? _iconColor(context)
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
        return Icon(Icons.star, color: HalcyonTokens.of(context).starred, size: 16);
      case PhotoStatus.trashed:
        return Icon(
          recycleMode ? Icons.restore_from_trash : Icons.delete,
          color: HalcyonTokens.of(context).danger,
          size: 16,
        );
      case PhotoStatus.unmarked:
        return const SizedBox.shrink();
    }
  }

  Widget _buildListThumbnail(AppState state, String id) {
    final payload = state.thumbnailPayloadFor(id);
    if (payload == null) {
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
      child: Image(
        image: _thumbnailProvider(payload),
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }

  ImageProvider _thumbnailProvider(SourcePayload payload) {
    switch (payload) {
      case EncodedPayload(:final bytes):
        // M1 (image-pipeline redesign, docs/logs/2026-08-23/
        // image-pipeline-redesign-handover.md §6 M1): width/height on
        // Image.memory alone are LAYOUT constraints only — the decoder still
        // produces a full-resolution bitmap. Cap the DECODE itself at
        // 32 * devicePixelRatio on the longest edge via ResizeImage's `fit`
        // policy, which fits the source within a cap x cap box while
        // preserving aspect ratio — `exact` (or naive cacheWidth +
        // cacheHeight) would silently squash non-square sources.
        final cap = (32 * MediaQuery.devicePixelRatioOf(context)).round();
        return ResizeImage(
          MemoryImage(bytes),
          width: cap,
          height: cap,
          policy: ResizeImagePolicy.fit,
        );
      case PixelPayload():
        // NOT wrapped in ResizeImage, deliberately: ResizeImage applies its
        // cap only through the `decode` callback it hands down
        // (flutter image_provider.dart:1350-1418), and RawPixelsImage ignores
        // that callback -- it builds the image with decodeImageFromPixels
        // (raw_pixels_image.dart:36-45). A wrapper here would cap nothing
        // while reading in review as protection that exists. The bound is
        // enforced at PRODUCTION time instead: the payload is already capped
        // at 200px long edge (image_preload_controller.dart, RAW branch), and
        // TC-373 asserts that on the payload rather than on a wrapper.
        return RawPixelsImage(payload);
    }
  }

  Widget _buildTopActions(BuildContext context) {
    final iconColor = _iconColor(context);

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
        // The single overflow menu, shared with every layout theme (T4).
        AppActionsMenu(iconColor: iconColor),
      ],
    );
  }
}
