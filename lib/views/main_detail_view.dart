import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import '../providers/app_state.dart';
import '../services/decoded_rgba_image_provider.dart';
import '../services/image_preload_controller.dart';
import 'photo_action_bar.dart';

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
        Positioned.fill(
          child: _buildZoomableViewer(
            bytes,
            state.currentItemHasFullSize,
            currentId, // PERF-INSTRUMENTATION
            state.currentDecodedProvider,
          ),
        ),

        // Floating Action Bar (Bottom Center)
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Center(child: PhotoActionBar(item: item)),
        ),
      ],
    );
  }

  // PERF-INSTRUMENTATION: measures provider resolve (bytes-in-cache ->
  // decoded -> painted), tagged with which tier actually resolved. Keyed by
  // "id:tier" (not just id) so a later tier-2 upgrade for the SAME id
  // WITHIN THE SAME switch (after an earlier tier-1 resolve) is logged as
  // its own event, matching the round-2 parser's tier2-UPGRADE classification.
  //
  // Scope: _perfTrackedKeys must be cleared per SWITCH (per new selection),
  // not once for the whole process lifetime. An earlier version only ever
  // cleared it at construction, so once a given (id, tier) pair had been
  // seen -- e.g. during the paced pass -- it never fired again for that same
  // id/tier revisited in a later switch (e.g. the rapid pass re-walking the
  // same photo set), silently producing zero `image.resolved` events for
  // every switch after the first pass. Detected via round-2's own report
  // shape (n=24 resolved=24 per pass, i.e. one full re-emit per pass) not
  // matching a live run's near-zero rapid-pass resolved count.
  String? _perfSpinnerId;
  String? _perfLastTrackedId;
  Set<String> _perfTrackedKeys = {};
  final Map<String, int> _perfOccCount = {};

  // Called once per NEW selection (id change), before any per-build perf
  // tracking, so the dedupe set resets at switch boundaries instead of
  // persisting for the process lifetime.
  void _perfResetForSwitch(String id) {
    if (!PerfLog.enabled) return;
    if (_perfLastTrackedId == id) return;
    _perfLastTrackedId = id;
    _perfTrackedKeys = {};
  }

  void _perfSpinner(String id) {
    if (!PerfLog.enabled) return;
    if (_perfSpinnerId != id) {
      _perfSpinnerId = id;
      PerfLog.log('view.spinner|$id');
    }
  }

  void _perfTrack(
    BuildContext context,
    String id,
    ImageProvider provider,
    int tier,
  ) {
    if (!PerfLog.enabled) return;
    final key = '$id:$tier';
    if (_perfTrackedKeys.contains(key)) return;
    _perfTrackedKeys.add(key);
    final occ = _perfOccCount.update(id, (v) => v + 1, ifAbsent: () => 0);
    final t0 = PerfLog.us;

    // Resolves through the SAME provider object (and therefore the same
    // ImageStream/ImageCache key+configuration) as the Image widget below,
    // so this observes the real decode/cache-hit rather than causing an
    // extra one.
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, sync) {
      PerfLog.log(
        'image.resolved|$id|occ=$occ|tier=$tier|sync=$sync'
        '|dur=${PerfLog.us - t0}',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PerfLog.log('image.painted|$id|tier=$tier|dur=${PerfLog.us - t0}');
        PerfLog.onImageReady?.call(id);
      });
      WidgetsBinding.instance.scheduleFrame();
      stream.removeListener(listener);
    });
    stream.addListener(listener);
  }

  Widget _buildZoomableViewer(
    Uint8List? bytes,
    bool useFullSize,
    String currentId, // PERF-INSTRUMENTATION
    DecodedRgbaImageProvider? decodedProvider,
  ) {
    _perfResetForSwitch(currentId); // PERF-INSTRUMENTATION
    // A raw-decoded DNG has no preview bytes by construction, so "no bytes"
    // is only a spinner when there is no decoded image either.
    if (bytes == null && decodedProvider == null) {
      _perfSpinner(currentId); // PERF-INSTRUMENTATION
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

        // Tier-1 decode target = window logical size x devicePixelRatio.
        // Forward it to AppState so the preload controller's precache
        // decodes neighboring images at the SAME resolution this Image
        // requests below (same provider factory, same size params ==
        // same ImageCache key == cache hit instead of a silent second
        // decode).
        final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final targetWidth = (constraints.maxWidth * devicePixelRatio).round();
        final targetHeight = (constraints.maxHeight * devicePixelRatio).round();
        context.read<AppState>().setViewportSize(targetWidth, targetHeight);

        // useFullSize (AppState.currentItemHasFullSize) is true only when
        // BOTH: the tier-2 decode for the CURRENT bytes has actually
        // COMPLETED (not merely started -- ImageCache.containsKey alone
        // would also be true for a still-pending decode), AND the
        // resulting entry is still resident under that same bytes object.
        // Selecting it here is therefore a plain ImageCache hit, exactly
        // like the tier-1 branch below, and never triggers (or waits on) a
        // decode on this build/UI path -- the check itself is bookkeeping,
        // not a resolve.
        // A decoded RAW image is ALREADY full resolution and already
        // orientation-corrected, and its item has no bytes to fall back to,
        // so it wins outright over both byte-backed tiers. The provider
        // object comes from the preload controller (not built here) so the
        // display path and the controller's eviction share one object
        // identity, exactly as the two byte-backed factories require.
        final ImageProvider provider =
            decodedProvider ??
            (useFullSize
                ? fullSizeProviderFor(bytes!)
                : tierOneProviderFor(
                    bytes!,
                    width: targetWidth,
                    height: targetHeight,
                  ));
        final isFullResolution = decodedProvider != null || useFullSize;

        // PERF-INSTRUMENTATION
        _perfTrack(context, currentId, provider, isFullResolution ? 2 : 1);

        final image =
            (isFullResolution || (targetWidth > 0 && targetHeight > 0))
            ? Image(
                image: provider,
                fit: BoxFit.contain,
                gaplessPlayback:
                    true, // Prevent flickering when switching images/tiers
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.broken_image, size: 64),
              )
            : Image.memory(
                bytes!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.broken_image, size: 64),
              );

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
            child: Center(child: image),
          ),
        );
      },
    );
  }
}
