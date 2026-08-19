import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../models/photo_item.dart';
import 'sidebar_view.dart';
import 'main_detail_view.dart';
import 'status_line.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final FocusNode _focusNode = FocusNode();
  double _sidebarWidth = 270.0;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          _buildKeyboardShortcutHandler(context: context, child: _buildBody()),
          const StatusLine(),
        ],
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
            Expanded(child: const MainDetailView()),
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
        if (event is KeyDownEvent) {
          final state = context.read<AppState>();

          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            state.previousPhoto();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            state.nextPhoto();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyS) {
            if (state.selectedItemID != null) {
              state.markCurrent(PhotoStatus.starred);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyX) {
            if (state.selectedItemID != null) {
              state.markCurrent(PhotoStatus.trashed);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            state.stepZoomIn();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            state.stepZoomOut();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
