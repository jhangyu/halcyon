import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/photo_item.dart';
import '../../../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import '../../../providers/app_state.dart';
import '../../../services/image_pipeline/photo_payload.dart';
import '../../../services/image_pipeline/payload_state.dart';
import '../../zoom_controller.dart';
import 'app_actions_menu.dart' show openFolderShortcutLabel;
import 'photo_thumbnail.dart' show thumbnailProviderFor;
import '../darkroom/darkroom_empty_state.dart';
import '../gallery/gallery_palette.dart';
import '../layout_theme.dart';
import '../paper/paper_welcome.dart';

/// The photo itself: empty state, spinner, unreadable state or the
/// InteractiveViewer. Extracted from the old per-detail-view photo widget
/// (T2 of the gallery layout plan) so a layout theme can position it
/// without redrawing it.
class PhotoViewport extends StatefulWidget {
  /// Zoom state, owned by `MainScreen` so it outlives photo switches.
  final ZoomController zoom;

  const PhotoViewport({super.key, required this.zoom});

  @override
  State<PhotoViewport> createState() => _PhotoViewportState();
}

class _PhotoViewportState extends State<PhotoViewport>
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
  void didUpdateWidget(PhotoViewport oldWidget) {
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
      // Each theme draws its own welcome screen (gallery frame 7, paper
      // frame 8, darkroom frame 6). The old stock Material fallback was
      // removed 2026-09-02: the exhaustive switch guarantees every theme
      // resolves to a real welcome screen, and a new enum case fails to
      // compile here until it declares one.
      switch (state.layoutThemeId) {
        case LayoutThemeId.gallery:
          return const _GalleryEmptyState();
        case LayoutThemeId.paper:
          return const PaperEmptyState();
        case LayoutThemeId.darkroom:
          return const DarkroomEmptyState();
      }
    }

    final currentId = state.selectedItemID;
    final item = state.currentItem;

    if (currentId == null || item == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        // Viewer Area
        //
        // PHASE 5: the viewer subtree repaints off the SELECTED ITEM'S OWN
        // payload state, not off every app-wide notification. The state value
        // itself is deliberately unused below -- what to paint is still
        // decided by AppState's existing getters (full-size readiness /
        // interim thumbnail / failure), which are the pipeline's single
        // source of truth; the
        // listenable only says WHEN to re-read them. Reading them inside this
        // builder is what makes the read fresh.
        Positioned.fill(
          child: ValueListenableBuilder<PayloadState>(
            valueListenable: state.payloadStateFor(currentId),
            builder: (context, _, _) => state.currentItemFailed
                ? _buildUnreadable(item)
                : _buildZoomableViewer(
                    state.currentItemHasFullSize,
                    currentId, // PERF-INSTRUMENTATION
                    state.displayProvider,
                    state.thumbnailPayloadFor(currentId),
                  ),
          ),
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
  /// The last decode target reported while the layout was NOT mid-drag.
  /// Reused verbatim for every frozen frame, so the long edge reported to the
  /// pipeline does not churn across a whole drag.
  (int, int)? _settledTarget;

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
      // R7 (l1l2): the SDK hands each listener its OWN clone; the listener owns it.
      info.dispose();
    });
    stream.addListener(listener);
  }

  // Kept for the non-gallery branch above and for the unreadable state.
  //
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
    bool useFullSize,
    String currentId, // PERF-INSTRUMENTATION
    ImageProvider? displayProvider, // AppState.displayProvider
    SourcePayload? interimThumbnail, // AppState.thumbnailPayloadFor
  ) {
    _perfResetForSwitch(currentId); // PERF-INSTRUMENTATION
    // ONE decoded tier (memory.md AD-072): the full-size entry, or a pixel
    // payload painted directly. Until it is resident the view shows the
    // sidebar's already-derived thumbnail -- a source that exists without any
    // decode of its own -- and only a spinner when even that is absent. No
    // viewport-resolution decode is ever started here.
    final ImageProvider? provider =
        displayProvider ??
        (interimThumbnail == null
            ? null
            : thumbnailProviderFor(interimThumbnail));
    if (provider == null) {
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

        // Decode target = window logical size x devicePixelRatio, reported
        // to AppState as the long edge the pipeline asks its loader for.
        //
        // While a gutter drag is in flight the layout reflows on every frame
        // (see GalleryDesktopSurface's reflow rule), so this target would
        // change on every frame too, and every new long edge re-measures each
        // file's cost (PrefetchScheduler's per-long-edge memo).
        // `DecodeSizeFreeze` marks those frames: the last settled target is
        // reported for the whole gesture and the real one lands once, when
        // the drag stalls. The layout itself is never frozen.
        final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final liveWidth = (constraints.maxWidth * devicePixelRatio).round();
        final liveHeight = (constraints.maxHeight * devicePixelRatio).round();

        final frozen = DecodeSizeFreeze.of(context) && _settledTarget != null;
        final targetWidth = frozen ? _settledTarget!.$1 : liveWidth;
        final targetHeight = frozen ? _settledTarget!.$2 : liveHeight;
        if (!frozen) _settledTarget = (liveWidth, liveHeight);
        context.read<AppState>().setViewportSize(targetWidth, targetHeight);

        // PERF-INSTRUMENTATION: tier 2 = full resolution, 1 = interim.
        _perfTrack(context, currentId, provider, useFullSize ? 2 : 1);

        final image = Image(
          image: provider,
          fit: BoxFit.contain,
          gaplessPlayback:
              true, // Prevent flickering when switching images/tiers
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

/// Marks the frames during which the decode target must be held steady.
///
/// The user's 2026-09-02 ruling made the gallery viewport reflow as the gutter
/// is dragged, which is a layout change per frame. Layout is cheap; a changed
/// decode target is not — every new long edge re-measures each file's cost in
/// the pipeline. A surface that reflows continuously wraps its viewport in
/// this with `frozen: true` for the duration, and [PhotoViewport] keeps
/// reporting the last settled size until it turns false again.
///
/// Absent (no ancestor) means "never frozen", so every other surface and every
/// test that does not care is unaffected.
class DecodeSizeFreeze extends InheritedWidget {
  const DecodeSizeFreeze({
    super.key,
    required this.frozen,
    required super.child,
  });

  final bool frozen;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DecodeSizeFreeze>()
          ?.frozen ??
      false;

  @override
  bool updateShouldNotify(DecodeSizeFreeze oldWidget) =>
      oldWidget.frozen != frozen;
}

/// The `gallery` theme's welcome screen — the state the app opens in
/// (mockup frame 7, `c1-desktop-{light,dark}.html:401-446`, added 2026-09-02).
///
/// Drawn from the parts every other frame already uses and no others: the
/// mount rectangle of the print, the wall-label typography of the EXIF
/// caption, the 44px hairline, and the accent button. The composition is the
/// app with nothing in it, so the layout the user is about to get is legible
/// before they open anything.
///
/// ALIGNMENT (user review of frame 7): every item sits on ONE centred axis.
/// The button is alone on its row — it must never share a [Row] with the
/// shortcut hint, because a centred row centres THE ROW, pushing the button
/// off-axis by half the hint's width. The shortcut lives inside the centred
/// drop-hint line below instead.
class _GalleryEmptyState extends StatelessWidget {
  const _GalleryEmptyState();

  /// Test handles for the single-axis assertion and element checks.
  static const Key mountKey = Key('galleryEmptyMount');
  static const Key buttonKey = Key('galleryEmptyOpenFolder');
  static const Key hintKey = Key('galleryEmptyDropHint');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = GalleryPalette.of(context);

    return ColoredBox(
      color: palette.mat, // --mat, the mount wall
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // An empty mount at the photo's own 3:2, so the shape is a promise.
            Container(
              key: mountKey,
              width: 432,
              height: 288,
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor, // --canvas
                border: Border.all(color: colors.outline), // --hair-strong
              ),
              child: Padding(
                padding: const EdgeInsets.all(11),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.outlineVariant), // --hair
                  ),
                ),
              ),
            ),
            const SizedBox(height: 38),
            Text(
              // `.empty .kicker{text-transform:uppercase}` — the mockup's own
              // casing, applied here rather than to the literal so the word
              // stays readable as the product name in source.
              'Halcyon'.toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 0.22 * 9,
                color: palette.textFaint,
              ),
            ),
            const SizedBox(height: 11),
            Text(
              'No folder open',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.01 * 19,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 392),
              child: Text(
                'Open a folder of RAW or JPEG files to browse it, star the '
                'keepers, mark the rejects, then copy or move what you kept.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  letterSpacing: 0.02 * 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Container(width: 44, height: 1, color: colors.outline),
            const SizedBox(height: 18),
            // Alone on its row, shrink-wrapped: the axis rule above.
            FilledButton.icon(
              key: buttonKey,
              onPressed: () => context.read<AppState>().openFolder(),
              style: FilledButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: palette.onAccent, // --on-accent, AA on both
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              icon: const Icon(Icons.folder_open, size: 15),
              label: const Text('Open Folder'),
            ),
            const SizedBox(height: 14),
            // One centred hint line; the shortcut is separated by colour and a
            // word space only — trailing letter-spacing on the last glyph would
            // shift the whole line off the axis.
            Text.rich(
              key: hintKey,
              TextSpan(
                children: [
                  TextSpan(
                    // Same chord the menu advertises, written for this
                    // platform (see openFolderShortcutLabel).
                    text: openFolderShortcutLabel(),
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const TextSpan(text: ' or drop a folder onto the window'),
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.06 * 10.5,
                color: palette.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
