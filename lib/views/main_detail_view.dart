import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/photo_item.dart';
import '../providers/app_state.dart';
import 'layout/common/photo_viewport.dart';
import 'photo_action_bar.dart';
import 'zoom_controller.dart';

class MainDetailView extends StatelessWidget {
  /// Zoom state, owned by `MainScreen` so it outlives photo switches.
  final ZoomController zoom;

  const MainDetailView({super.key, required this.zoom});

  @override
  Widget build(BuildContext context) {
    final item = context.select<AppState, PhotoItem?>((s) => s.currentItem);

    // Action bar only when a photo is actually selected — matching the old
    // MainDetailView, which returned early (spinner / empty state, no bar)
    // before reaching the action bar with no current item.
    return Stack(
      children: [
        // Viewer Area
        Positioned.fill(child: PhotoViewport(zoom: zoom)),

        // Floating Action Bar (Bottom Center)
        if (item != null)
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(child: PhotoActionBar(item: item)),
          ),
      ],
    );
  }
}