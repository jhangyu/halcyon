import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../models/photo_item.dart';
import '../models/shortcut_bindings.dart';
import 'layout/common/app_actions_menu.dart';
import 'layout/common/photo_viewport.dart';
import 'layout/layout_registry.dart';
import 'layout/main_surface.dart';
import 'status_line.dart';
import 'zoom_controller.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final FocusNode _focusNode = FocusNode();

  // Owned here, not by the photo viewport widget: the viewport is rebuilt
  // on photo switches and the zoom level must survive those (handover §11).
  final ZoomController _zoom = ZoomController();

  @override
  void dispose() {
    _focusNode.dispose();
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      // Disabled under a modal route (e.g. a rename/confirm dialog): a drop
      // there would call openPhotoAtPath -> loadFolder and swap the folder
      // out from under a dialog whose action still reads state at execution
      // time, landing renames/deletes in a folder the user never previewed.
      enable: ModalRoute.of(context)?.isCurrent ?? true,
      onDragDone: (detail) {
        if (detail.files.isEmpty) return;
        // Same entry as OS Open-With: load the folder, select that photo.
        context.read<AppState>().openPhotoAtPath(detail.files.first.path);
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            _buildKeyboardShortcutHandler(
              context: context,
              child: _buildSurface(context),
            ),
            const StatusLine(),
          ],
        ),
      ),
    );
  }

  Widget _buildSurface(BuildContext context) {
    final state = context.watch<AppState>();
    final item = state.currentItem;
    final index = item == null
        ? 0
        : state.items.indexWhere((i) => i.id == item.id) + 1;
    return activeLayoutTheme.buildMainSurface(
      context,
      MainSurface(
        viewport: PhotoViewport(key: kViewportKey, zoom: _zoom),
        statusOverlay: const StatusLine(),
        strip: PhotoStripModel(
          items: state.items,
          selectedId: state.selectedItemID,
          recycleMode: state.recycleMode,
          onSelect: state.selectItem,
          payloadFor: state.thumbnailPayloadFor,
          onVisibleRange: state.preloadThumbnails,
        ),
        identity: item == null
            ? null
            : PhotoIdentity(
                displayName: item.displayName,
                indexInFolder: index,
                folderCount: state.items.length,
                status: item.status,
                exif: state.currentExif,
              ),
        actions: PhotoActions(
          recycleMode: state.recycleMode,
          onStar: () => state.markCurrent(PhotoStatus.starred),
          onTrash: () => state.markCurrent(PhotoStatus.trashed),
          onToggleRecycleMode: state.toggleRecycleMode,
          onOpenFolder: state.openFolder,
          menu: AppActionsMenu(
            iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildKeyboardShortcutHandler({
    required BuildContext context,
    required Widget child,
  }) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final state = context.read<AppState>();
        final action = state.shortcutBindings.actionFor(event.logicalKey);
        if (action == null) return KeyEventResult.ignored;
        switch (action) {
          case ShortcutAction.previousPhoto:
            state.previousPhoto();
          case ShortcutAction.nextPhoto:
            state.nextPhoto();
          case ShortcutAction.starPhoto:
            if (state.selectedItemID != null) {
              state.markCurrent(PhotoStatus.starred);
            }
          case ShortcutAction.trashMarkPhoto:
            if (state.selectedItemID != null) {
              state.markCurrent(PhotoStatus.trashed);
            }
          case ShortcutAction.zoomIn:
            _zoom.stepZoomIn();
          case ShortcutAction.zoomOut:
            _zoom.stepZoomOut();
          case ShortcutAction.toggleRecycleMode:
            state.toggleRecycleMode();
        }
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
