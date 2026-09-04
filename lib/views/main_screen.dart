import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
    // W3 (residual-jank-diagnosis.md fix #6): a single choke point for every
    // pointer signal (click, drag, scroll wheel/momentum) at the root of the
    // screen, feeding the idle-publish scheduler's input-recency check --
    // cheaper than instrumenting each scrollable individually and it cannot
    // miss a new one added later.
    return Listener(
      onPointerDown: (_) => context.read<AppState>().noteInputActivity(),
      onPointerMove: (_) => context.read<AppState>().noteInputActivity(),
      onPointerSignal: (_) => context.read<AppState>().noteInputActivity(),
      child: _buildDropTarget(context),
    );
  }

  Widget _buildDropTarget(BuildContext context) {
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
        // No standalone StatusLine here: `_buildSurface` already threads one
        // through `MainSurface.statusOverlay`, which the active layout theme
        // (gallery_desktop.dart) positions per the mockup (`Positioned(left:
        // 106, bottom: 20)`). A second bare `const StatusLine()` used to sit
        // in this Stack too — both are independently-stateful widgets that
        // listen to the same AppState toast stream, so any status message
        // rendered twice, overlapping.
        body: _buildKeyboardShortcutHandler(
          context: context,
          child: _buildSurface(context),
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
    // Mobile layout is a PLATFORM decision, not a window-size one: only
    // Android/iOS get the mobile surface (three-round contract, round 3).
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // Round 4: the active layout theme is a persisted user setting, not a
    // constant. `state` is already watched above, so changing it in Settings
    // rebuilds this surface.
    final theme = layoutThemeFor(state.layoutThemeId);
    final build = mobile ? theme.buildMobileSurface : theme.buildMainSurface;
    return build(
      context,
      MainSurface(
        viewport: RepaintBoundary(
          child: PhotoViewport(key: kViewportKey, zoom: _zoom),
        ),
        statusOverlay: const StatusLine(),
        strip: PhotoStripModel(
          items: state.items,
          selectedId: state.selectedItemID,
          recycleMode: state.recycleMode,
          onSelect: state.selectItem,
          payloadFor: state.thumbnailPayloadFor,
          onVisibleRange: state.preloadThumbnails,
          revision: state.thumbnailsRevision,
        ),
        identity: item == null
            ? null
            : PhotoIdentity(
                displayName: item.displayName,
                indexInFolder: index,
                folderCount: state.items.length,
                status: item.status,
                exif: state.currentExif,
                starredCount: state.starredCount,
                trashedCount: state.trashedCount,
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
        // Chord-aware: openFolder (Cmd+O / Ctrl+O, see ShortcutBindings.
        // actionForChord) is the one action that REQUIRES a modifier: every
        // other action must NOT fire while a modifier is held.
        final action = state.shortcutBindings.actionForChord(
          event.logicalKey,
          meta: HardwareKeyboard.instance.isMetaPressed,
          control: HardwareKeyboard.instance.isControlPressed,
        );
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
          case ShortcutAction.openFolder:
            state.openFolder();
        }
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
