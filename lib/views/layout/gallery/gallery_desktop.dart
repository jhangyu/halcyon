import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/exif_caption.dart';
import '../common/photo_viewport.dart';
import '../main_surface.dart';
import 'gallery_column.dart';
import 'gallery_palette.dart';

/// Constants for the dragged column width state, ruled R5a/R8 on 2026-09-01.
///
/// The lower bound moved from 180 to 90 — the resting gutter width — so
/// dragging fully left returns the strip to sitting BESIDE the photo at zero
/// image cost. The upper bound moved from 600 to 200, set by what the
/// thumbnail source can supply (200 physical px on the long edge), not taste.
const double kGalleryColumnMinWidth = 90.0;
const double kGalleryColumnMaxWidth = 200.0;

/// Test key on the float-shadow `DecoratedBox` that wraps [GalleryColumn], so
/// TC-506 can assert the shadow toggles on `_columnWidth > 90` without reaching
/// into the column's own internals.
const ValueKey<String> kGalleryColumnShadowKey =
    ValueKey<String>('gallery.column.shadow');

/// Test key on the width-readout badge, so tests can assert it is absent at
/// rest and present while a drag is in flight.
const ValueKey<String> kGalleryWidthBadgeKey =
    ValueKey<String>('gallery.width.badge');

/// Key on the gutter's `Positioned` slot in the desktop `Stack`, so that slot
/// can never be reconciled against a sibling `Positioned` (see the comment at
/// the width-readout child — that is what killed the resize drag).
const ValueKey<String> kGalleryColumnSlotKey =
    ValueKey<String>('gallery.column.slot');

/// Test key on the resize handle's outer dead zone — the sliver of hit region
/// that lies over the photo viewport rather than inside the gutter.
const ValueKey<String> kGalleryHandleDeadZoneKey =
    ValueKey<String>('gallery.handle.deadzone');

/// How long after the last width delta the width-readout badge stays visible.
/// Deltas keep arriving for the whole gesture, so this is reset on every delta
/// and only expires once the drag truly stalls.
const Duration kGalleryWidthBadgeDelay = Duration(milliseconds: 400);

/// The desktop arrangement of the `gallery` theme (T6 of the gallery layout
/// plan).
///
/// Stateful because it owns the dragged column width — a theme-specific number
/// that a theme without a strip must not carry (T10 rules it out of
/// `MainScreen`). Everything this theme is allowed to arrange comes in as a
/// [MainSurface] with behaviours already resolved; this widget only positions.
///
/// ## The width readout badge while dragging
///
/// [GalleryColumn] reports only width deltas through [PhotoActions]-independent
/// [GalleryColumn.onWidthDelta]; it gives no pan-start/pan-end signal. The
/// desktop therefore infers "drag in flight" from the deltas themselves: the
/// first delta marks the badge active, and a [Timer] that is reset on every
/// delta hides it again a short while after the deltas stop (a drag stall, not
/// a persistent indicator). The badge is desktop-owned because the width and the
/// drag state both live here; it needs no column metadata (plan T6:841-843).
///
/// ## The reflow rule (USER RULING 2026-09-02, supersedes plan R5)
///
/// The viewport's left inset is the LIVE `_columnWidth`. A widened gutter
/// pushes the photo instead of floating over it, so the strip never covers
/// any part of the image; the seam and the handle dead zone ride the same
/// edge. The photo is 1350 × 900 only at the resting width of 90 — above it
/// the photo is narrower by exactly the extra gutter width.
///
/// What this deliberately gives up, recorded so nobody "rediscovers" it as a
/// bug: the previous `min(_columnWidth, 90)` inset kept the constraints the
/// viewport's internal `LayoutBuilder` sees CONSTANT during a drag, so
/// `setViewportSize` never changed mid-drag and the tier-1 `ImageProvider`
/// cache key was stable by construction (AD-011). With a reflowing viewport
/// the tier-1 decode target changes on every drag frame, so a drag can cost
/// repeated tier-1 decodes. The user ruled that not overlapping the photo is
/// worth that, and the cost is paid back by the mitigation below rather than
/// by bringing the overlap back.
///
/// ## Holding the decode size still during a drag
///
/// The viewport is wrapped in a [DecodeSizeFreeze] carrying `_dragActive`.
/// Layout still reflows on every frame — the photo visibly gives up width as
/// the gutter grows — but [PhotoViewport] keeps REPORTING and decoding at the
/// last settled target while the flag is true, so the tier-1 `ImageProvider`
/// cache key is identical for the whole gesture and the real target lands
/// once, when the drag stalls. AD-011's identity rule is preserved without
/// the overlap; the image is `BoxFit.contain`, so a frame decoded at the
/// pre-drag target simply scales for the few hundred ms the drag lasts.
class GalleryDesktopSurface extends StatefulWidget {
  const GalleryDesktopSurface({super.key, required this.surface});

  final MainSurface surface;

  @override
  State<GalleryDesktopSurface> createState() => _GalleryDesktopSurfaceState();
}

class _GalleryDesktopSurfaceState extends State<GalleryDesktopSurface> {
  // The EXACT accumulated width, resting at the free gutter width (which IS
  // the minimum of the range).
  //
  // Load-bearing that this is unrounded: pointer deltas arrive fractional (a
  // trackpad or a slow mouse move reports well under 1 logical px per event).
  // Rounding the accumulator itself — `_columnWidth = (_columnWidth + dx)
  // .roundToDouble()` — quantises every individual delta instead of the
  // total, so a stream of 0.4px deltas rounds to +0 forever and the gutter
  // never moves at all, while 0.6px deltas each round to +1 and it moves
  // nearly twice as fast as the pointer. Measured before the fix: 150 x 0.4px
  // (a 60px drag) produced 0px of movement; 100 x 0.6px produced 100px.
  double _rawColumnWidth = kGalleryColumnMinWidth;

  /// The width actually handed to layout: whole pixels, so the gutter never
  /// paints on a subpixel seam. Rounding happens HERE, at the consumer, never
  /// in the accumulator above.
  double get _columnWidth => _rawColumnWidth.roundToDouble();

  // True only while a drag is in flight, so the width readout badge is shown
  // during the gesture and hidden once it stalls (see [GalleryDesktopSurface]).
  bool _dragActive = false;
  Timer? _dragStallTimer;

  /// Holds primary focus so the Open Folder chord below is delivered here
  /// (see the note at the `Focus` that consumes it).
  final FocusNode _shortcutFocus = FocusNode(debugLabel: 'gallery.shortcuts');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _shortcutFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _shortcutFocus.dispose();
    _dragStallTimer?.cancel();
    super.dispose();
  }

  /// The column's drag callback (main_screen.dart:74-78 arithmetic, bounds
  /// re-ruled R5a/R8): add the pointer delta, round to whole px (prevents
  /// subpixel seams), then clamp to [90, 200]. `num.clamp` returns `num`, so
  /// the `toDouble()` is load-bearing for the `double` field.
  ///
  /// Every delta also marks the "drag in flight" flag true and resets the
  /// stall timer, so the width badge shows while deltas keep flowing and hides
  /// [kGalleryWidthBadgeDelay] after they stop.
  void _onWidthDelta(double dx) {
    _dragStallTimer?.cancel();
    setState(() {
      // Accumulate raw, clamp raw, round only on the way out (see the field).
      // Clamping the accumulator (rather than only the rounded output) is what
      // keeps the gutter responsive the instant the pointer turns around: an
      // unclamped accumulator would wind far past the bound while the user
      // keeps pushing, then owe that whole distance back before anything moved.
      _rawColumnWidth = (_rawColumnWidth + dx)
          .clamp(kGalleryColumnMinWidth, kGalleryColumnMaxWidth)
          .toDouble();
      _dragActive = true;
    });
    _dragStallTimer = Timer(kGalleryWidthBadgeDelay, () {
      if (mounted) setState(() => _dragActive = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    // USER RULING 2026-09-02, superseding the R5 float rule: a widened gutter
    // must PUSH the photo, never cover it. The viewport's left inset is
    // therefore the LIVE column width, so the strip and the photo always
    // partition the window between them and nothing is overlapped. See the
    // class doc for the decode cost this trades away.
    final viewportLeft = _columnWidth;
    final floating = _columnWidth > kGalleryColumnMinWidth;
    final colors = Theme.of(context).colorScheme;

    // ⌘O / Ctrl+O — Open Folder.
    //
    // DELIBERATELY HARD-CODED HERE, not in `ShortcutBindings`. That model
    // dispatches on the logical key ALONE (main_screen.dart's handler reads
    // `actionFor(event.logicalKey)`) and has no representation for a
    // modifier, so it cannot express this chord at all today. "Cmd+O opens a
    // folder" is a platform convention rather than a user preference, so a
    // fixed binding is defensible; if rebindability is ever wanted, the
    // upgrade path is to add modifier support plus an `openFolder` action to
    // ShortcutBindings and delete this wrapper, not to grow it.
    //
    // Both activators are registered so the affordance exists on every
    // desktop platform (macOS uses meta, Windows/Linux control); the two
    // labels that advertise it are platform-aware for the same reason.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
            surface.actions.onOpenFolder,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            surface.actions.onOpenFolder,
      },
      child: Focus(
        // Explicitly focused once at mount rather than via `autofocus`:
        // main_screen already autofocuses its own Focus ABOVE this one, and a
        // scope honours only the first autofocus, so this node would never
        // hold primary focus and the chord would be delivered to the ancestor
        // instead — dead in the product while passing in isolation.
        // Taking focus here is safe for the app's other shortcuts: key events
        // propagate from the focused node UP through its ancestors, so
        // main_screen's handler still sees everything this node does not bind.
        focusNode: _shortcutFocus,
        child: _buildStack(context, surface, viewportLeft, floating, colors),
      ),
    );
  }

  Widget _buildStack(
    BuildContext context,
    MainSurface surface,
    double viewportLeft,
    bool floating,
    ColorScheme colors,
  ) {
    return Stack(
      children: [
        // The photo, inset by the live column width. Explicit insets only —
        // never Padding/FractionallySizedBox (R-D1).
        Positioned(
          left: viewportLeft,
          top: 0,
          right: 0,
          bottom: 0,
          // Reflow the layout every frame, but hold the DECODE target steady
          // until the drag stalls (see the class doc's trade-off note).
          child: DecodeSizeFreeze(
            frozen: _dragActive,
            child: surface.viewport,
          ),
        ),
        // Hairline seam marking where the gutter ends and the photo begins
        // (mockup `.seam`). It rides the gutter's right edge, which is now
        // also the photo's left edge.
        Positioned(
          left: viewportLeft,
          top: 0,
          bottom: 0,
          width: 1,
          child: ColoredBox(color: colors.outlineVariant),
        ),
        // R4 EXIF corner caption, bottom-right, museum-label manner.
        Positioned(
          right: 20,
          bottom: 16,
          // The file name is the label's title line since the 2026-09-02
          // mockup revision; it used to live in the column's identity plate.
          child: ExifCaption(
            fileName: surface.identity?.displayName,
            exif: surface.identity?.exif,
          ),
        ),
        // Transient status toast, floats over the photo (mockup `.status`).
        Positioned(
          left: 106,
          bottom: 20,
          child: surface.statusOverlay,
        ),
        // Width readout while dragging (mockup `.wtag`, top 14 / right 14 /
        // radius 20 / padding 3v-10h / 10px). Shown only while a drag is in
        // flight, so it never lingers over the photo at rest.
        //
        // The width readout occupies a PERMANENT slot and empties itself when
        // idle; it must never be a `if (_dragActive) Positioned(...)`
        // conditional child. Every child of this Stack is an unkeyed
        // `Positioned`, so `Widget.canUpdate` returns true between ANY pair of
        // them: inserting one mid-list shifts every following slot by one, and
        // Flutter then updates each surviving element with its NEIGHBOUR's
        // widget. The gutter's element (and with it the resize handle's
        // GestureDetector, and with it the live pan recognizer) was therefore
        // destroyed the instant the first delta set `_dragActive` — which is
        // why a resize drag moved 1-2px and then went dead for the rest of the
        // gesture. Measured: a 60px drag delivered 4px before the fix and the
        // full 60px after it.
        Positioned(
          top: 14,
          right: 14,
          child: IgnorePointer(
            child: !_dragActive
                ? const SizedBox.shrink()
                : Container(
                    key: kGalleryWidthBadgeKey,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${_columnWidth.round()} px',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.08 * 10, // 0.08 em at 10px
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
        ),
        // The gutter column + drag handle. Its own Positioned grows over the
        // photo while the viewport inset stays pinned (the float rule); the
        // float shadow is painted here, on the desktop, only while floating.
        Positioned(
          // Belt and braces against the slot-shift failure described above:
          // with a key, `canUpdate` is false against any other Stack child, so
          // this element can only ever be matched with itself — a future
          // conditional sibling cannot silently steal the gutter's element and
          // kill the live pan recognizer again.
          key: kGalleryColumnSlotKey,
          left: 0,
          top: 0,
          bottom: 0,
          width: _columnWidth,
          child: DecoratedBox(
            key: kGalleryColumnShadowKey,
            decoration: BoxDecoration(
              boxShadow: floating
                  ? [
                      // mockup `.gutter.dragged`: 12px 0 34px at 16%.
                      // The colour is the palette's shared floatShadow token;
                      // offset/blur stay layout-owned here (R6 lead ruling).
                      BoxShadow(
                        color: GalleryPalette.of(context).floatShadow,
                        offset: const Offset(12, 0),
                        blurRadius: 34,
                      ),
                    ]
                  : null,
            ),
            child: GalleryColumn(
              surface: surface,
              width: _columnWidth,
              onWidthDelta: _onWidthDelta,
            ),
          ),
        ),
        // The outer half of the resize handle's hit region. The gutter's own
        // Stack clips, so it cannot hit-test past its right edge; without this
        // strip a pointer-down one or two pixels right of the grip lands in
        // the viewport's InteractiveViewer and becomes an image pan instead of
        // a resize. Last child, so it wins the hit test against the viewport;
        // it paints nothing and only forwards the same deltas the grip does.
        Positioned(
          key: kGalleryHandleDeadZoneKey,
          left: _columnWidth,
          top: 0,
          bottom: 0,
          width: kGalleryHandleOverhang,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) => _onWidthDelta(details.delta.dx),
            ),
          ),
        ),
      ],
    );
  }
}
