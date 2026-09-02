// T17: the geometry gate (TC-529, plan TC-522 +7). Contract acceptance #4:
// "At 1440x900, the widget keyed by kViewportKey is exactly 1350x900 at
// column widths 90, 120, 160, and 200."
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

Future<void> _dragColumnTo(WidgetTester tester, double target) async {
  for (var i = 0; i < 10; i++) {
    final current =
        tester.getSize(find.byKey(kGalleryColumnShadowKey)).width;
    final dx = target - current;
    if (dx.abs() < 0.5) return;
    await _dragColumnHandle(tester, Offset(dx, 0));
  }
}

Offset _handleStart(WidgetTester tester) {
  final topLeft = tester.getTopLeft(find.byKey(kGalleryColumnShadowKey));
  final width = tester.getSize(find.byKey(kGalleryColumnShadowKey)).width;
  return topLeft + Offset(width - 2.5, 50);
}

Future<void> _dragColumnHandle(WidgetTester tester, Offset delta) async {
  final start = _handleStart(tester);
  final gesture = await tester.startGesture(start);
  final dir = delta.dx.isNegative ? -1.0 : 1.0;
  await gesture.moveBy(Offset(dir * 19.0, 0));
  await gesture.moveBy(delta);
  await gesture.up();
  await tester.pump();
}

void main() {
  for (final width in <double>[90, 120, 160, 200]) {
    testWidgets('TC-529 photo is 1350x900 with the column at $width', (
      tester,
    ) async {
      await pumpGalleryDesktop(tester, columnWidth: width);
      final box = tester.renderObject<RenderBox>(find.byKey(kViewportKey));
      expect(box.size, const Size(1350, 900));
    });
  }
}
