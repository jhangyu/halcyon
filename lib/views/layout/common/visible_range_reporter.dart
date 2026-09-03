import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../main_surface.dart';
import 'anchored_scroll.dart';

/// The ONE implementation of the AD-014 contract: the strip reports the rows it
/// BUILT, from `itemBuilder`, deferred to the end of the frame — never from a
/// scroll listener, and never with a prefetch margin of its own (the margin is
/// the preload controller's business).
///
/// Extracted 2026-09-03 from five copies that had drifted apart. The policy
/// here is `gallery_column.dart`'s, the most defensive of the five: when the
/// list has no scroll position yet, report the accumulated built range instead
/// of reporting nothing.
///
/// That fallback is a genuine safety net rather than a first-frame fix. A
/// `ScrollController` attaches during the LAYOUT phase, which precedes the
/// post-frame callback in the same frame, and `itemBuilder` only ever runs
/// during that same layout — so on an ordinary first frame `hasClients` is
/// already true and the geometry path is taken. Measured 2026-09-03; the plan
/// that commissioned this extraction assumed otherwise. The fallback still
/// covers the cases that have no geometry to work from at all: a strip with no
/// controller, and the horizontal mobile strip, which has no uniform row extent
/// to divide by (it passes a null [rangeRowExtent]).
///
/// A State mixing this in supplies its own geometry.
mixin VisibleRangeReporter<T extends StatefulWidget> on State<T> {
  /// The strip's scroll controller, or null if it has none yet.
  ScrollController? get rangeScrollController;

  /// The strip model whose `onVisibleRange` is called.
  PhotoStripModel get rangeStrip;

  /// Items per row. 1 for a single-column strip.
  int get rangeColumns => 1;

  /// Uniform row pitch in logical pixels, or null for built-index-only mode.
  double? get rangeRowExtent => null;

  int _first = -1;
  int _last = -1;
  bool _scheduled = false;

  /// Call from `itemBuilder` with the index being built. Never calls
  /// `setState`, never calls `onVisibleRange` synchronously: a report during
  /// build would notifyListeners mid-build.
  void noteBuiltIndex(int index) {
    if (_first == -1 || index < _first) _first = index;
    if (index > _last) _last = index;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final first = _first;
      final last = _last;
      _first = -1;
      _last = -1;
      if (!mounted) return;
      final strip = rangeStrip;
      final controller = rangeScrollController;
      final extent = rangeRowExtent;
      if (controller == null ||
          !controller.hasClients ||
          extent == null ||
          extent <= 0) {
        // No geometry to report from: the built indices are the only evidence
        // there is. Nothing built means nothing to say.
        if (first != -1) strip.onVisibleRange(first, last);
        return;
      }
      final columns = rangeColumns;
      final offset = controller.offset;
      final viewportHeight = controller.position.viewportDimension;
      final firstRow = (offset / extent).floor();
      final lastRow = ((offset + viewportHeight) / extent).ceil();
      strip.onVisibleRange(
        math.max(0, firstRow * columns),
        math.min(lastRow * columns + (columns - 1), strip.items.length - 1),
      );
    });
  }
}

/// The resize re-anchor every filmstrip performs in `didUpdateWidget`.
///
/// Resizing the gutter changes the row extent, which re-maps every row's pixel
/// position under a FIXED offset — the "scroll drifts off the current photo
/// while dragging" bug. The correction is ARMED here and APPLIED inside the
/// coming layout pass (see [AnchoredScrollPosition]); deferring it to a
/// post-frame callback would paint one frame at the old offset under the new
/// extent, which IS the flash the user sees (TC-556).
///
/// [columnsFor]/[rowExtentFor] are asked for the old and the new width
/// separately, so a strip whose column count also changes with width (darkroom,
/// the paper float strip) is handled by the same code as one whose does not.
/// Keeps the currently-selected row inside the strip's visible viewport,
/// scrolling with a 200ms `Curves.easeInOut` animation when it is not.
///
/// This is the keyboard-navigation follow-scroll contract: every filmstrip
/// must call this whenever `strip.selectedId` changes (selection moved via
/// arrow keys or any other path), not just on drag/resize. Extracted from
/// `gallery_column.dart`'s `_ensureSelectedVisible` (the only theme that had
/// it) so `darkroom_column.dart` and `paper_desktop.dart` share the exact
/// same behaviour instead of leaving it unimplemented.
///
/// Does not fight user-initiated scrolling: it only moves the offset when the
/// selected row's bounds fall outside `[offset, offset + viewportHeight]`, so
/// scrolling the strip without changing the selection never triggers a jump.
void ensureSelectedRowVisible({
  required ScrollController controller,
  required PhotoStripModel strip,
  required int columns,
  required double rowExtent,
}) {
  final selectedId = strip.selectedId;
  final items = strip.items;
  if (selectedId == null || items.isEmpty) return;
  if (!controller.hasClients) return;

  final idx = items.indexWhere((i) => i.id == selectedId);
  if (idx == -1) return;

  final row = idx ~/ columns;
  final itemTop = row * rowExtent;
  final itemBottom = itemTop + rowExtent;
  final viewportOffset = controller.offset;
  final viewportHeight = controller.position.viewportDimension;

  if (itemTop < viewportOffset) {
    controller.animateTo(
      itemTop,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  } else if (itemBottom > viewportOffset + viewportHeight) {
    controller.animateTo(
      itemBottom - viewportHeight,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }
}

void anchorSelectedRowOnWidthChange({
  required AnchoredScrollController controller,
  required PhotoStripModel strip,
  required int Function(double width) columnsFor,
  required double Function(double width) rowExtentFor,
  required double oldWidth,
  required double newWidth,
}) {
  final selectedId = strip.selectedId;
  if (selectedId == null || strip.items.isEmpty) return;
  final idx = strip.items.indexWhere((i) => i.id == selectedId);
  if (idx == -1) return;
  // No `hasClients` guard: `anchorRowByPixelOffset` already returns early
  // without a position (anchored_scroll.dart), so adding one here would only
  // duplicate it.
  controller.anchorRowByPixelOffset(
    oldRow: idx ~/ columnsFor(oldWidth),
    oldRowExtent: rowExtentFor(oldWidth),
    newRow: () => idx ~/ columnsFor(newWidth),
    newRowExtent: () => rowExtentFor(newWidth),
  );
}
