import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
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
  // USER RULING 2026-09-02 supersedes the float rule this group used to
  // assert. The gutter must PUSH the photo, not cover it, so the viewport is
  // 1350x900 only at the resting width; at every wider position it is
  // narrower by exactly the extra gutter width. The invariant is now
  // "viewport width + column width == window width", not a fixed 1350.
  group('TC-505 the viewport gives up exactly the gutter\'s width', () {
    for (final width in [90.0, 120.0, 160.0, 200.0]) {
      testWidgets('viewport at column width ${width.round()}',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        await pumpDesktop(tester, surface: minimalSurface());

        if (width > 90) {
          await _dragColumnTo(tester, width);
        }

        final box = tester.renderObject(find.byKey(kViewportKey))
            as RenderBox;
        expect(box.size, Size(1440 - width, 900));
        await tester.binding.setSurfaceSize(null);
      });
    }
  });

  group('TC-540 a widened gutter never overlaps the photo', () {
    for (final width in [90.0, 120.0, 160.0, 200.0]) {
      testWidgets('no overlap at column width ${width.round()}',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        await pumpDesktop(tester, surface: minimalSurface());

        if (width > 90) {
          await _dragColumnTo(tester, width);
        }

        final viewport = tester.getRect(find.byKey(kViewportKey));
        final gutter = tester.getRect(find.byType(GalleryColumn));

        // The photo starts exactly where the gutter ends: no gap, no overlap.
        expect(viewport.left, closeTo(width, 0.5));
        expect(gutter.right, closeTo(viewport.left, 0.5));
        expect(viewport.right, closeTo(1440, 0.5));
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

/// Converges the column to [target]: with a single member in the pan
/// gesture's arena (no competing scrollable here), the recognizer accepts
/// immediately and delivers the FULL requested delta with no touch slop
/// eaten (the same fact this file's TC-513-equivalent handle drag relies on)
/// — so a fresh gesture per iteration, each moving exactly the remaining
/// `target - current`, converges in one shot. `_dragColumnHandle`'s extra
/// artificial "slop" offset is fine for the huge, clamp-bound deltas TC-507
/// uses, but paying it here on top of an exact delta delivers as a real,
/// uncompensated delta and oscillates forever without converging. Asserts
/// convergence so a helper that stalls fails loudly instead of silently
/// returning short.
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

double _currentWidth(WidgetTester tester) {
  return tester.getSize(find.byKey(kGalleryColumnShadowKey)).width;
}
