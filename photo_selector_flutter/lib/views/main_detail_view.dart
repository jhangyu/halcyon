import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/photo_item.dart';

class MainDetailView extends StatefulWidget {
  const MainDetailView({super.key});

  @override
  State<MainDetailView> createState() => _MainDetailViewState();
}

class _MainDetailViewState extends State<MainDetailView>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  Animation<Matrix4>? _zoomAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _animController.addListener(() {
      if (_zoomAnimation != null) {
        context.read<AppState>().transformCtrl.value = _zoomAnimation!.value;
      }
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            const Text(
              "Select a folder to begin",
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => context.read<AppState>().openFolder(),
              icon: const Icon(Icons.folder_open),
              label: const Text("Open Folder"),
            ),
          ],
        ),
      );
    }

    final currentId = state.selectedItemID;
    final item = state.currentItem;
    final bytes = state.currentImageBytes;

    if (currentId == null || item == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Trigger animation if requested by AppState
    if (state.shouldAnimateZoom && state.targetMatrix != null) {
      _zoomAnimation =
          Matrix4Tween(
            begin: state.transformCtrl.value,
            end: state.targetMatrix!,
          ).animate(
            CurvedAnimation(
              parent: _animController,
              curve: Curves.fastOutSlowIn,
            ),
          );

      _animController.forward(from: 0);

      // Reset the flag off-frame so we don't continuously re-trigger
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<AppState>().shouldAnimateZoom = false;
        }
      });
    }

    return Stack(
      children: [
        // Viewer Area
        Positioned.fill(child: _buildZoomableViewer(bytes)),

        // Floating Action Bar (Bottom Center)
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
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
                      item.status == PhotoStatus.starred
                          ? Icons.star
                          : Icons.star_border,
                      color: item.status == PhotoStatus.starred
                          ? Colors.amber
                          : null,
                    ),
                    onPressed: () => context.read<AppState>().markCurrent(
                      PhotoStatus.starred,
                    ),
                    tooltip: 'Star (S)',
                  ),
                  const SizedBox(width: 20),
                  IconButton(
                    icon: Icon(
                      item.status == PhotoStatus.trashed
                          ? Icons.delete
                          : Icons.delete_outline,
                      color: item.status == PhotoStatus.trashed
                          ? Colors.red
                          : null,
                    ),
                    onPressed: () => context.read<AppState>().markCurrent(
                      PhotoStatus.trashed,
                    ),
                    tooltip: 'Trash (X)',
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildZoomableViewer(dynamic bytes) {
    if (bytes == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final center = Offset(
          constraints.maxWidth / 2,
          constraints.maxHeight / 2,
        );
        // Silently update layout center
        context.read<AppState>().lastKnownCenter = center;

        return MouseRegion(
          onHover: (event) {
            context.read<AppState>().pointerPosition = event.localPosition;
          },
          onExit: (event) {
            context.read<AppState>().pointerPosition = null;
          },
          child: InteractiveViewer(
            transformationController: context.read<AppState>().transformCtrl,
            minScale: 1.0,
            maxScale: 5.0,
            trackpadScrollCausesScale: true,
            child: Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback:
                    true, // Prevent flickering when switching images
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.broken_image, size: 64),
              ),
            ),
          ),
        );
      },
    );
  }
}
