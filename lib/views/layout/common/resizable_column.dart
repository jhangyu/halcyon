import 'dart:async';

import 'package:flutter/widgets.dart';

/// THE drag-stall delay, identical across the three desktop themes.
/// [ResizableColumnDrag.dragActive] stays true until this long after the last
/// width delta.
const Duration kColumnDragStallDelay = Duration(milliseconds: 400);

/// One implementation of the desktop gutter's drag rule and drag-stall timer.
/// Mixing states supply only what differs per theme: the min/max (and, for
/// paper, the resting) width.
///
/// Accumulate RAW, clamp raw, round only on read. Load-bearing that the
/// accumulator is unrounded: pointer deltas arrive fractional (a trackpad or
/// a slow mouse move reports well under 1 logical px per event). Rounding
/// the accumulator itself quantises every individual delta instead of the
/// total, so a stream of 0.4px deltas rounds to +0 forever and the gutter
/// never moves at all, while 0.6px deltas each round to +1 and it moves
/// nearly twice as fast as the pointer. Measured before the fix: 150 x 0.4px
/// (a 60px drag) produced 0px of movement; 100 x 0.6px produced 100px.
/// Clamping the RAW value matters too: an unclamped accumulator would wind
/// far past the bound while the user drags beyond it, and the gutter would
/// then refuse to move back until the pointer unwound the excess.
mixin ResizableColumnDrag<T extends StatefulWidget> on State<T> {
  double get columnMinWidth;
  double get columnMaxWidth;

  /// Where the column rests before any drag. Paper overrides (its resting
  /// width is not its minimum).
  double get initialColumnWidth => columnMinWidth;

  // Lazily initialised on first read, which is in build(), after the state
  // is fully constructed.
  late double _rawColumnWidth = initialColumnWidth;

  /// The width actually handed to layout: whole pixels, so the gutter never
  /// paints on a subpixel seam. Rounding happens HERE, at the consumer, never
  /// in the accumulator.
  double get columnWidth => _rawColumnWidth.roundToDouble();

  /// True from the first width delta until [kColumnDragStallDelay] after the
  /// last one: drives the width badge and `DecodeSizeFreeze`.
  bool get dragActive => _dragActive;
  bool _dragActive = false;
  Timer? _dragStallTimer;

  /// Feed one pointer delta (logical px, may be fractional).
  void onWidthDelta(double dx) {
    _dragStallTimer?.cancel();
    setState(() {
      _rawColumnWidth = (_rawColumnWidth + dx)
          .clamp(columnMinWidth, columnMaxWidth)
          .toDouble();
      _dragActive = true;
    });
    _dragStallTimer = Timer(kColumnDragStallDelay, () {
      if (mounted) setState(() => _dragActive = false);
    });
  }

  @override
  void dispose() {
    _dragStallTimer?.cancel();
    super.dispose();
  }
}
