import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_desktop.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

/// Builds the desktop surface at a fixed 1440x900 window with a minimal,
/// unthemed [MainSurface].
///
/// The viewport is a plain keyed [ColoredBox] so the geometry gate can measure
/// its `RenderBox` against the expected 1350x900 exactly, with no theme or
/// pipeline behaviour in the way. The strip/identity/actions are left empty
/// because [GalleryColumn] (T7) consumes them only to render; no test here
/// drives the strip.
Future<void> pumpDesktop(
  WidgetTester tester, {
  required MainSurface surface,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GalleryDesktopSurface(surface: surface),
      ),
    ),
  );
}

MainSurface minimalSurface({Widget? viewport}) {
  return MainSurface(
    viewport:
        viewport ?? const ColoredBox(key: kViewportKey, color: Colors.red),
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
}

void main() {
  group('TC-505 viewport geometry is exactly 1350x900 at four widths', () {
    for (final width in [90.0, 120.0, 160.0, 200.0]) {
      testWidgets('viewport at column width ${width.round()}',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        await pumpDesktop(tester, surface: minimalSurface());

        if (width > 90) {
          await _dragColumnTo(tester, width);
        }

        // The float rule: for every width in the range the inset is pinned at
        // 90, so the viewport is exactly 1350 wide regardless of the column.
        final box = tester.renderObject(find.byKey(kViewportKey))
            as RenderBox;
        expect(box.size, const Size(1350, 900));
        await tester.binding.setSurfaceSize(null);
      });
    }
  });

  group('TC-506 float shadow toggles at the 90px threshold', () {
    testWidgets('no shadow at exactly 90', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      final shadowDecor = tester.widget<DecoratedBox>(
        find.byKey(kGalleryColumnShadowKey),
      );
      expect((shadowDecor.decoration as BoxDecoration).boxShadow, isNull);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('shadow present above 90', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      await _dragColumnTo(tester, 120);

      final shadowDecor = tester.widget<DecoratedBox>(
        find.byKey(kGalleryColumnShadowKey),
      );
      final shadows =
          (shadowDecor.decoration as BoxDecoration).boxShadow!;
      expect(shadows, isNotEmpty);
      expect(shadows.first.offset, const Offset(12, 0));
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('width readout badge only while a drag is in flight', () {
    testWidgets('absent at rest', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      expect(find.byKey(kGalleryWidthBadgeKey), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('present mid-drag and hidden again after the drag stalls',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      // Start a real handle drag but don't release yet: the badge must be up.
      final gesture = await tester.startGesture(_handleStart(tester));
      await gesture.moveBy(const Offset(19, 0)); // accept the pan (slop)
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();

      expect(find.byKey(kGalleryWidthBadgeKey), findsOneWidget);

      // Keep feeding deltas so the stall timer never fires mid-gesture.
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(kGalleryWidthBadgeKey), findsOneWidget);

      // Release; once the deltas stop, the badge hides shortly after.
      await gesture.up();
      await tester.pump();
      expect(find.byKey(kGalleryWidthBadgeKey), findsOneWidget);

      await tester.pump(
        kGalleryWidthBadgeDelay + const Duration(milliseconds: 50),
      );
      expect(find.byKey(kGalleryWidthBadgeKey), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-507 both drag clamps, both directions', () {
    testWidgets('drag far left from 90 clamps to 90', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      // Drag the handle -300 logical px from the resting 90.
      await _dragColumnHandle(tester, const Offset(-300, 0));

      expect(_currentWidth(tester), kGalleryColumnMinWidth);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('drag far right from 200 clamps to 200', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      // First push the column to the ceiling.
      await _dragColumnTo(tester, 200);

      // Then drag +300 from 200 -> clamped back to 200.
      await _dragColumnHandle(tester, const Offset(300, 0));

      expect(_currentWidth(tester), kGalleryColumnMaxWidth);
      await tester.binding.setSurfaceSize(null);
    });
  });
}

/// The column's resize handle sits at the right edge of the float-shadow
/// wrapper (which is as wide as the column). The handle is a 5px-wide
/// full-height hit area at that edge (GalleryColumn T7), so its centre is a
/// couple of px in from the right edge, near the top.
Offset _handleStart(WidgetTester tester) {
  final topLeft = tester.getTopLeft(find.byKey(kGalleryColumnShadowKey));
  final width = tester.getSize(find.byKey(kGalleryColumnShadowKey)).width;
  return topLeft + Offset(width - 2.5, 50);
}

/// A single pan on the handle. Because a `GestureDetector` pan consumes the
/// touch slop before the first `onPanUpdate`, one big `moveBy` may under-deliver
/// by up to the slop; the clamp tests tolerate that (both deltas are huge), and
/// the geometry loop re-reads the actual width and re-drags until it converges.
Future<void> _dragColumnHandle(WidgetTester tester, Offset delta) async {
  final start = _handleStart(tester);
  final gesture = await tester.startGesture(start);
  final dir = delta.dx.isNegative ? -1.0 : 1.0;
  // Exceed the default touch slop (GestureBinding/ktouchSlop = 18) so the
  // pan is accepted; this slop excursion is absorbed by the framework and NOT
  // delivered as a drag delta, so add it on top of the real delta.
  await gesture.moveBy(Offset(dir * 19.0, 0));
  // Every subsequent move now reports its full delta to onPanUpdate.
  await gesture.moveBy(delta);
  await gesture.up();
  await tester.pump();
}

/// Converges the column to [target] width by reading the actual rendered width
/// and re-dragging until it lands within tolerance.
Future<void> _dragColumnTo(WidgetTester tester, double target) async {
  for (var i = 0; i < 10; i++) {
    final current = _currentWidth(tester);
    final dx = target - current;
    if (dx.abs() < 0.5) return;
    await _dragColumnHandle(tester, Offset(dx, 0));
  }
}

double _currentWidth(WidgetTester tester) {
  return tester.getSize(find.byKey(kGalleryColumnShadowKey)).width;
}
