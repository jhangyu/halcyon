import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/photo_item.dart';
import '../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import '../providers/app_state.dart';
import '../services/image_preload_controller.dart';
import '../services/raw_pixels_image.dart';
import 'photo_action_bar.dart';
import 'zoom_controller.dart';

class MainDetailView extends StatefulWidget {
  /// Zoom state, owned by `MainScreen` so it outlives photo switches.
  final ZoomController zoom;

  const MainDetailView({super.key, required this.zoom});

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
        widget.zoom.transformCtrl.value = _zoomAnimation!.value;
      }
    });
    widget.zoom.addListener(_onZoomRequested);
  }

  @override
  void didUpdateWidget(MainDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoom != widget.zoom) {
      oldWidget.zoom.removeListener(_onZoomRequested);
      widget.zoom.addListener(_onZoomRequested);
    }
  }

  /// Consumes the controller's one-shot animation request. This runs off the
  /// controller's notification rather than from `build()`, so the flag is
  /// cleared immediately by its only consumer instead of via a post-frame
  /// callback, and no zoom state is written during a build.
  void _onZoomRequested() {
    final zoom = widget.zoom;
    final target = zoom.targetMatrix;
    if (!zoom.shouldAnimateZoom || target == null) return;
    zoom.shouldAnimateZoom = false;

    _zoomAnimation =
        Matrix4Tween(begin: zoom.transformCtrl.value, end: target).animate(
          CurvedAnimation(parent: _animController, curve: Curves.fastOutSlowIn),
        );
    _animController.forward(from: 0);
  }

  @override
  void dispose() {
    widget.zoom.removeListener(_onZoomRequested);
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

    return Stack(
      children: [
        // Viewer Area
        Positioned.fill(
          child: state.currentItemFailed
              ? _buildUnreadable(item)
              : _buildZoomableViewer(
                  bytes,
                  state.currentItemHasFullSize,
                  currentId, // PERF-INSTRUMENTATION
                  state.currentDecodedProvider,
                  state.currentFullResProvider,
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

  // Shown instead of the otherwise-permanent spinner when the file is
  // unreadable (AppState.currentItemFailed).
  Widget _buildUnreadable(PhotoItem item) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, size: 64),
          const SizedBox(height: 12),
          Text('無法讀取「${item.displayName}」\n檔案可能已損毀或格式不支援'),
        ],
      ),
    );
  }

  Widget _buildZoomableViewer(
    Uint8List? bytes,
    bool useFullSize,
    String currentId, // PERF-INSTRUMENTATION
    RawPixelsImage? decodedProvider,
    ImageProvider? fullResProvider,
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
        // Silently update layout center: a plain field write, deliberately
        // NOT a notifying setter -- notifying from inside a LayoutBuilder
        // builder would rebuild forever.
        widget.zoom.lastKnownCenter = center;

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
        // A pixel-backed (RAW-decoded) item has no bytes to fall back to, so
        // it wins outright over both byte-backed tiers. Since M5 it has two
        // tiers of its own: [fullResProvider] is the FULL-RESOLUTION tier-2
        // entry, non-null only while it is resident for the item's current
        // payload, and [decodedProvider] is the window-resolution tier-1
        // fallback used before the upgrade lands, after it is evicted, or when
        // the full-res decode failed. Both provider objects come from the
        // preload controller (not built here) so the display path and the
        // controller's eviction share one object identity, exactly as the two
        // byte-backed factories require -- and for the full-res one that is
        // load-bearing rather than merely tidy: it is one-shot, so only the
        // controller's own object resolves as a cache hit.
        final ImageProvider provider = decodedProvider != null
            ? (fullResProvider ?? decodedProvider)
            : (useFullSize
                  ? fullSizeProviderFor(bytes!)
                  : tierOneProviderFor(
                      bytes!,
                      width: targetWidth,
                      height: targetHeight,
                    ));
        // Honest tiering: a pixel item painting its window-resolution provider
        // IS tier 1, and before M5 it was mislabelled tier 2 here.
        final isFullResolution = decodedProvider != null
            ? fullResProvider != null
            : useFullSize;

        // PERF-INSTRUMENTATION
        _perfTrack(context, currentId, provider, isFullResolution ? 2 : 1);

        // `decodedProvider != null` is kept as its own term: a pixel item has
        // no bytes at all, so the Image.memory fallback below is not merely
        // suboptimal for it, it would dereference a null.
        final image =
            (decodedProvider != null ||
                isFullResolution ||
                (targetWidth > 0 && targetHeight > 0))
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
            widget.zoom.pointerPosition = event.localPosition;
          },
          onExit: (event) {
            widget.zoom.pointerPosition = null;
          },
          child: InteractiveViewer(
            transformationController: widget.zoom.transformCtrl,
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
