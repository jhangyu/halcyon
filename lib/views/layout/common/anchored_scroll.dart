import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/widgets.dart';

/// Resolves the offset a strip should sit at, given the geometry the layout
/// pass has just measured. Returns null to leave the offset alone.
typedef AnchorResolver =
    double? Function(double viewportDimension, double maxScrollExtent);

/// A [ScrollPosition] that can re-anchor itself DURING layout.
///
/// This exists because of the resize flicker (TC-556, first fixed inside
/// `gallery/gallery_column.dart` and lifted here in round 4 so every theme's
/// filmstrip can use it). Dragging a gutter changes the strip's row extent,
/// which re-maps every row's pixel position under a fixed scroll offset; the
/// strip therefore has to be re-anchored on the selected row on every drag
/// frame. Doing that with a post-frame `jumpTo` is what produced the flicker:
/// the frame that FIRST shows the new row extent is painted at the OLD offset
/// (displacing every row by `row * dExtent` — enough, at row 15, to push the
/// selected chip out of the viewport entirely) and only the NEXT frame pulls
/// it back. At drag rates that alternation is the visible flash.
///
/// [correctPixels] is the framework's sanctioned answer, and the reason this
/// is a position subclass rather than a controller call: it may only be used
/// while layout is in flight, and returning `false` from
/// [applyContentDimensions] makes the viewport re-run layout with the
/// corrected offset before anything is painted. The correction therefore
/// lands in the SAME frame as the geometry change, and no stale frame exists
/// to be seen. It also gets the REAL `viewportDimension`/`maxScrollExtent`
/// rather than the previous frame's, so no extent has to be estimated.
class AnchoredScrollPosition extends ScrollPositionWithSingleContext {
  AnchoredScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  /// Consumed by the next layout pass, then cleared. Set on a width change.
  AnchorResolver? pendingAnchor;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final resolve = pendingAnchor;
    if (resolve != null) {
      pendingAnchor = null;
      final target = resolve(viewportDimension, maxScrollExtent);
      if (target != null) {
        final clamped = target.clamp(minScrollExtent, maxScrollExtent);
        if ((clamped - pixels).abs() > precisionErrorTolerance) {
          correctPixels(clamped);
          // Not accepted: the viewport lays out again, now at the anchored
          // offset. `pendingAnchor` is already null, so that second pass
          // falls through to `super` and settles.
          return false;
        }
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// Hands out [AnchoredScrollPosition]s and keeps a reference to the live one
/// so a filmstrip state can arm an anchor for the next layout pass.
class AnchoredScrollController extends ScrollController {
  AnchoredScrollPosition? _position;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _position = AnchoredScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
    );
  }

  /// Arms a one-shot correction consumed by the next layout pass.
  void anchorNextLayout(AnchorResolver resolve) {
    _position?.pendingAnchor = resolve;
  }

  /// Arms the standard filmstrip anchor: keep the row that is currently
  /// selected at the same PIXEL distance below the viewport's top edge, under
  /// whatever row extent the coming layout pass produces.
  ///
  /// Call from `didUpdateWidget` after the widget has been swapped in, so
  /// [newRowExtent] (evaluated during the layout pass) reads the NEW geometry
  /// while [oldRowExtent]/[oldRow] describe the frame being left behind.
  ///
  /// ## Why pixels and not a viewport fraction (round-4 fix)
  ///
  /// The first version of this anchored on the row's viewport FRACTION. That
  /// silently made a SECOND geometry change visible: the gallery gutter's
  /// marks row is a `Wrap`, and as the gutter widens its five children reflow
  /// from four runs onto two. That changes the fixed height BELOW the strip,
  /// so the strip's own viewport grows (measured: 590px at a 91px gutter,
  /// 706px at 120px and above). A fraction anchor faithfully re-derives the
  /// offset for the new viewport height and therefore SLIDES the whole strip
  /// by `fraction * dViewport` — the user-reported "the filmstrip shifts
  /// vertically while I drag the sidebar", a monotone shift rather than a
  /// flicker.
  ///
  /// A pixel-distance anchor does not react to viewport height at all: a
  /// top-aligned list whose viewport grows downward genuinely shows MORE at
  /// the bottom while everything already on screen stays exactly put, which
  /// is what "stays where you were looking" means. It also remains the
  /// correct answer for the row-extent change it was written for, because the
  /// row's own centre is recomputed from the new extent.
  void anchorRowByPixelOffset({
    required int oldRow,
    required double oldRowExtent,
    required int Function() newRow,
    required double Function() newRowExtent,
  }) {
    if (!hasClients) return;
    final oldCentre = oldRow * oldRowExtent + oldRowExtent / 2;
    final distanceBelowTop = oldCentre - offset;
    anchorNextLayout((viewportDimension, maxScrollExtent) {
      final extent = newRowExtent();
      final centre = newRow() * extent + extent / 2;
      return centre - distanceBelowTop;
    });
  }
}
