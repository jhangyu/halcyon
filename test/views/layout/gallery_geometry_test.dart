// T17: the geometry gate (TC-529, plan TC-522 +7). Originally: "at 1440x900
// the widget keyed by kViewportKey is exactly 1350x900 at column widths 90,
// 120, 160 and 200". USER RULING 2026-09-02 replaced the float rule with a
// reflow rule — the gutter pushes the photo instead of covering it — so the
// gate now asserts the partition: viewport width == window width minus the
// column width, and the viewport's left edge sits on the gutter's right edge.
//
// Deliberately distinct from gallery_desktop_test.dart's TC-505 (which
// already proves this same geometry, but by pumping GalleryDesktopSurface
// directly with a hand-built MainSurface): this file goes through
// `activeLayoutTheme.buildMainSurface` — the actual layout-theme SEAM T9/T10
// wired up — so it also catches a registry-wiring regression that TC-505,
// bypassing the seam, would not. TC-505 is not superseded and stays.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/views/layout/gallery/gallery_desktop.dart';
import 'package:halcyon_flutter/views/layout/layout_registry.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

/// Pumps the real seam (`activeLayoutTheme.buildMainSurface`) at a fixed
/// 1440x900 window, then drags the gutter column to [columnWidth] before
/// measuring. A minimal [MainSurface] (empty strip, no identity) is enough:
/// this test's only subject is the viewport geometry the layout theme
/// produces, not any strip/identity/actions behaviour.
Future<void> pumpGalleryDesktop(
  WidgetTester tester, {
  required double columnWidth,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final surface = MainSurface(
    viewport: const ColoredBox(key: kViewportKey, color: Colors.red),
    statusOverlay: const SizedBox.shrink(),
    strip: PhotoStripModel(
      items: const [],
      selectedId: null,
      recycleMode: false,
      onSelect: (_) {},
      payloadFor: (_) => null,
      onVisibleRange: (_, __) {},
    ),
    identity: null,
    actions: PhotoActions(
      recycleMode: false,
      onStar: () {},
      onTrash: () {},
      onToggleRecycleMode: () {},
      onOpenFolder: () {},
      menu: const SizedBox.shrink(),
    ),
  );

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        // buildMainSurface only needs a BuildContext to read Theme.of(context)
        // inside its descendants; a Builder supplies one from inside the tree
        // being built, matching how main_screen.dart's _buildSurface is
        // itself invoked from within MainScreen's own build().
        body: Builder(
          builder: (context) =>
              activeLayoutTheme.buildMainSurface(context, surface),
        ),
      ),
    ),
  );

  if (columnWidth != kGalleryColumnMinWidth) {
    await _dragColumnTo(tester, columnWidth);
  }
}

double _currentWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(kGalleryColumnShadowKey)).width;

Offset _handleStart(WidgetTester tester) {
  final topLeft = tester.getTopLeft(find.byKey(kGalleryColumnShadowKey));
  final width = tester.getSize(find.byKey(kGalleryColumnShadowKey)).width;
  return topLeft + Offset(width - 2.5, 50);
}

/// Converges the column to [target]: with a single member in the pan
/// gesture's arena (no competing scrollable here), the recognizer accepts
/// immediately and delivers the FULL requested delta with no touch slop
/// eaten (same fact `gallery_column_test.dart`'s TC-513 documents for this
/// handle) — so a fresh gesture per iteration, each moving exactly the
/// remaining `target - current`, converges in one shot. Paying an extra
/// artificial "slop" offset on top (the old helper's bug) actually delivers
/// as a real, uncompensated delta, overshooting and then oscillating forever
/// without converging. Asserts convergence so a helper that stalls fails
/// loudly instead of silently returning short.
Future<void> _dragColumnTo(WidgetTester tester, double target) async {
  for (var i = 0; i < 10; i++) {
    final current = _currentWidth(tester);
    final dx = target - current;
    if (dx.abs() < 0.5) break;
    final gesture = await tester.startGesture(_handleStart(tester));
    await gesture.moveBy(Offset(dx, 0));
    await gesture.up();
    await tester.pump();
  }
  expect(
    _currentWidth(tester),
    closeTo(target, 0.5),
    reason: 'drag helper failed to reach $target',
  );
}

void main() {
  for (final width in <double>[90, 120, 160, 200]) {
    testWidgets(
        'TC-529 photo fills the window beside the column at $width', (
      tester,
    ) async {
      await pumpGalleryDesktop(tester, columnWidth: width);
      final box = tester.renderObject<RenderBox>(find.byKey(kViewportKey));
      expect(box.size, Size(1440 - width, 900));
      expect(tester.getRect(find.byKey(kViewportKey)).left, closeTo(width, 0.5));
    });
  }
}
