import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../models/photo_item.dart';
import '../models/shortcut_bindings.dart';
import 'sidebar_view.dart';
import 'main_detail_view.dart';
import 'status_line.dart';
import 'zoom_controller.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final FocusNode _focusNode = FocusNode();
  double _sidebarWidth = 270.0;

  // Owned here, not by MainDetailView: the detail view is rebuilt on photo
  // switches and the zoom level must survive those (handover §11).
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
              child: _buildBody(),
            ),
            const StatusLine(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Row(
          children: [
            SizedBox(width: _sidebarWidth, child: const SidebarView()),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    _sidebarWidth += details.delta.dx;
                    // Provide some reasonable bounds and round to prevent 1px subpixel seams
                    _sidebarWidth = _sidebarWidth.roundToDouble();
                    if (_sidebarWidth < 180) _sidebarWidth = 180;
                    if (_sidebarWidth > 600) _sidebarWidth = 600;
                  });
                },
                child: Container(
                  width: 5, // 5px drag handle width
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color.fromARGB(255, 81, 81, 81)
                      : const Color.fromARGB(255, 225, 225, 225),
                ),
              ),
            ),
            Expanded(child: MainDetailView(zoom: _zoom)),
          ],
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
