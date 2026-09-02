import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/exif_caption.dart';
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
/// TC-499 can assert the shadow toggles on `_columnWidth > 90` without reaching
/// into the column's own internals.
const ValueKey<String> kGalleryColumnShadowKey =
    ValueKey<String>('gallery.column.shadow');

/// Test key on the width-readout badge, so tests can assert it is absent at
/// rest and present while a drag is in flight.
const ValueKey<String> kGalleryWidthBadgeKey =
    ValueKey<String>('gallery.width.badge');

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
/// ## The float rule (plan R5) — load-bearing, do not "simplify"
///
/// The viewport's left inset is `min(_columnWidth, 90.0)`, never
/// `_columnWidth`. At 90 the column sits BESIDE the photo; above 90 the
/// column's own `Positioned` grows over the top of the viewport while the
/// viewport's inset stays pinned at 90. That single `min` is the whole
/// "floats over, never pushes" mechanism, and it is why the photo measures
/// 1350 × 900 at every drag position in the 90-200 range.
///
/// It also buys a second property worth more than the first: because the inset
/// is pinned, the constraints the viewport's internal `LayoutBuilder` sees
/// never change while the user drags. So `setViewportSize` is never called
/// with new numbers mid-drag, and the tier-1 `ImageProvider` cache key stays
/// identical across the whole 90-200 range — the frozen AD-011 identity rule
/// is satisfied by construction here, not by discipline. Any formulation that
/// reflows the viewport as the column grows (`left: _columnWidth`, a `Row`, an
/// `Expanded`) would re-decode the full-frame image on every drag frame while
/// looking correct in a screenshot and passing every test except TC-498 — the
/// single most expensive mistake available in this task.
class GalleryDesktopSurface extends StatefulWidget {
  const GalleryDesktopSurface({super.key, required this.surface});

  final MainSurface surface;

  @override
  State<GalleryDesktopSurface> createState() => _GalleryDesktopSurfaceState();
}

class _GalleryDesktopSurfaceState extends State<GalleryDesktopSurface> {
  // Resting width: the free gutter width, which IS the minimum of the range.
  double _columnWidth = kGalleryColumnMinWidth;

  // True only while a drag is in flight, so the width readout badge is shown
  // during the gesture and hidden once it stalls (see [GalleryDesktopSurface]).
  bool _dragActive = false;
  Timer? _dragStallTimer;

  @override
  void dispose() {
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
      _columnWidth = (_columnWidth + dx)
          .roundToDouble()
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
    // The float rule. Pinned at 90 so the constraints the viewport's internal
    // LayoutBuilder sees never change while the user drags (see class doc).
    // `num.min` returns `num`; `toDouble()` is load-bearing for `Positioned.left`.
    final viewportLeft =
        math.min(_columnWidth, kGalleryColumnMinWidth).toDouble();
    final floating = _columnWidth > kGalleryColumnMinWidth;
    final colors = Theme.of(context).colorScheme;

    return Stack(
      children: [
        // The photo itself: 1350 x 900 at any width <= 90. Explicit insets
        // only — never Padding/FractionallySizedBox, or the constraints its
        // internal LayoutBuilder sees would change (R-D1).
        Positioned(
          left: viewportLeft,
          top: 0,
          right: 0,
          bottom: 0,
          child: surface.viewport,
        ),
        // Hairline seam marking where the free gutter ends and the photo
        // begins (mockup `.seam`). The photo's left edge never moves, so the
        // seam is pinned at 90 regardless of the dragged column.
        Positioned(
          left: kGalleryColumnMinWidth,
          top: 0,
          bottom: 0,
          width: 1,
          child: ColoredBox(color: colors.outlineVariant),
        ),
        // R4 EXIF corner caption, bottom-right, museum-label manner.
        Positioned(
          right: 20,
          bottom: 16,
          child: ExifCaption(exif: surface.identity?.exif),
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
        if (_dragActive)
          Positioned(
            top: 14,
            right: 14,
            child: IgnorePointer(
              child: Container(
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
      ],
    );
  }
}
