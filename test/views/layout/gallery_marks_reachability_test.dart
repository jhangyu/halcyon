import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_desktop.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

/// Regression gate for the two gallery-gutter defects reported 2026-09-02:
///
/// * TC-530 — dragging the gutter wider silently killed the rightmost mark
///   buttons. `_buildMarks` switched to a horizontal `Row` inside a
///   `SingleChildScrollView` whose intrinsic ~187px extent exceeded the gutter
///   at every width below 200, and the scroll viewport CLIPPED the remainder:
///   invisible and unhittable. Measured before the fix: `Open Folder` and the
///   menu both dead at 100/120, the menu dead at 140/160/179.
/// * TC-531 — below ~305px of window height the gutter `Column` overflowed and
///   pushed the marks outside the parent's bounds, again unhittable.
/// * TC-532 — the 5px resize handle was too narrow to grab: pointer-downs a
///   pixel or two right of the grip landed in the photo viewport and became
///   image pans instead of a resize. (A usability improvement, NOT the cause
///   of the "drag stalls" report — see TC-533/534 for that.)
/// * TC-533 — a resize drag started and then went dead after 1-2px. Two
///   independent defects, both above `GalleryColumn` (the pan recognizer
///   itself was proven healthy: it delivered 30/30 deltas summing to the full
///   60px when counted at the `onWidthDelta` boundary):
///   (a) the width readout was an `if (_dragActive) Positioned(...)`
///       conditional child of the desktop `Stack`. All children were unkeyed
///       `Positioned`s, so inserting one on the first delta shifted every
///       following slot and Flutter updated each surviving element with its
///       neighbour's widget — destroying the gutter's element, its
///       `GestureDetector` and the live recognizer mid-gesture.
///   (b) `_onWidthDelta` rounded the ACCUMULATOR (`(w + dx).roundToDouble()`),
///       quantising each individual delta rather than the total. 150 deltas of
///       0.4px (a 60px drag) moved the gutter 0px; 100 deltas of 0.6px moved
///       it 100px.
/// * TC-534 — the structural guards for (a): a constant Stack child count and
///   a keyed gutter slot.
///
/// Every assertion here is about HIT-TESTABILITY, not mere presence: a clipped
/// widget is still `findsOneWidget`, which is exactly how this shipped.

const _markIcons = <String, IconData>{
  'star': Icons.star_border,
  'trash': Icons.delete_outline,
  'folder': Icons.folder_open,
  'menu': Icons.more_horiz,
};

MainSurface _surface({VoidCallback? onOpenFolder}) {
  return MainSurface(
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
    identity: const PhotoIdentity(
      displayName: 'DSC_0001.NEF',
      indexInFolder: 3,
      folderCount: 120,
      status: PhotoStatus.unmarked,
      exif: null,
    ),
    actions: PhotoActions(
      recycleMode: false,
      onStar: () {},
      onTrash: () {},
      onToggleRecycleMode: () {},
      onOpenFolder: onOpenFolder ?? () {},
      // A real 40x40 icon button, not SizedBox.shrink(): the menu is the
      // widest and last mark, so a zero-sized stand-in would hide the very
      // overflow this gate exists to catch.
      menu: const Icon(Icons.more_horiz, size: 20),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Size window,
  MainSurface? surface,
}) async {
  await tester.binding.setSurfaceSize(window);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GalleryDesktopSurface(surface: surface ?? _surface()),
      ),
    ),
  );
  await tester.pump();
}

/// Drags the gutter's grip so the column settles at [width].
Future<void> _dragTo(WidgetTester tester, double width) async {
  if (width == kGalleryColumnMinWidth) return;
  await tester.drag(
    find.byKey(const ValueKey<String>('gallery-grip')),
    Offset(width - kGalleryColumnMinWidth, 0),
  );
  await tester.pump();
}

void main() {
  group('TC-530 every mark stays hittable at every dragged gutter width', () {
    for (final width in [90.0, 100.0, 120.0, 140.0, 160.0, 179.0, 200.0]) {
      testWidgets('gutter width ${width.round()}', (tester) async {
        await _pump(tester, window: const Size(1440, 900));
        await _dragTo(tester, width);

        for (final entry in _markIcons.entries) {
          final finder = find.byIcon(entry.value);
          expect(
            finder,
            findsOneWidget,
            reason: '${entry.key} must be built at width $width',
          );
          expect(
            finder.hitTestable(),
            findsOneWidget,
            reason:
                '${entry.key} is built but NOT hittable at width $width — it '
                'is clipped outside the gutter, the reported bug',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('TC-531 the gutter never overflows, at any window height', () {
    for (final height in [900.0, 400.0, 320.0, 300.0, 260.0, 200.0]) {
      testWidgets('window height ${height.round()}', (tester) async {
        await _pump(tester, window: Size(1440, height));
        // A RenderFlex overflow is reported as a pumped exception; before the
        // fix this fired at 300/260/200.
        expect(
          tester.takeException(),
          isNull,
          reason: 'gutter overflowed at window height $height',
        );
        for (final entry in _markIcons.entries) {
          expect(
            find.byIcon(entry.value),
            findsOneWidget,
            reason: '${entry.key} must still be built at height $height',
          );
        }
      });
    }

    // "Built" is a weaker claim than "usable", so every height that exercises
    // the scrolling branch also gets a real press, not just a findsOneWidget.
    for (final height in [300.0, 260.0, 200.0]) {
      testWidgets('marks stay pressable at a ${height.round()}px window height',
          (tester) async {
        // These heights must actually be under the threshold, or the test
        // silently stops exercising the scrolling branch it exists to cover.
        expect(kGalleryColumnMinContentHeight, greaterThan(height));
        var opened = 0;
        await _pump(
          tester,
          window: Size(1440, height),
          surface: _surface(onOpenFolder: () => opened++),
        );
        // `ensureVisible` is as much of the assertion as the tap: it throws if
        // the button has no enclosing scrollable, i.e. if the marks were
        // merely clipped away rather than made reachable.
        await tester.ensureVisible(find.byIcon(Icons.folder_open));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.folder_open));
        await tester.pump();
        expect(opened, 1, reason: 'Open Folder must be pressable at $height');
      });
    }
  });

  group('TC-532 the resize handle is grabbable without hitting the photo', () {
    testWidgets('the painted grip did not move when the hit band widened',
        (tester) async {
      await _pump(tester, window: const Size(1440, 900));
      final grip = tester.getRect(
        find.byKey(const ValueKey<String>('gallery-grip')),
      );
      // The 1px grip sits at [width-3, width-2] — byte-identical to where it
      // sat when it was centred in the old 5px band. Widening the hit region
      // must never move the visual.
      expect(grip.width, 1);
      expect(grip.left, kGalleryColumnMinWidth - 3);
      expect(grip.right, kGalleryColumnMinWidth - 2);
    });

    testWidgets('a pan 8px inside the edge resizes (old 5px band missed it)',
        (tester) async {
      await _pump(tester, window: const Size(1440, 900));
      // x = width-8 is inside the 12px band but was OUTSIDE the old 5px one.
      await tester.dragFrom(
        Offset(kGalleryColumnMinWidth - 8, 400),
        const Offset(40, 0),
      );
      await tester.pump();
      final column = tester.getSize(find.byKey(kGalleryColumnSlotKey));
      expect(
        column.width,
        kGalleryColumnMinWidth + 40,
        reason: 'the widened hit band must deliver the drag to the parent',
      );
    });

    testWidgets('a pan just RIGHT of the edge resizes instead of panning',
        (tester) async {
      await _pump(tester, window: const Size(1440, 900));
      // 2px into the photo viewport: the dead zone owned by the desktop
      // surface. Before the fix this reached the InteractiveViewer and became
      // an image pan, leaving the column width untouched.
      expect(find.byKey(kGalleryHandleDeadZoneKey), findsOneWidget);
      await tester.dragFrom(
        Offset(kGalleryColumnMinWidth + 2, 400),
        const Offset(30, 0),
      );
      await tester.pump();
      final column = tester.getSize(find.byKey(kGalleryColumnSlotKey));
      expect(
        column.width,
        kGalleryColumnMinWidth + 30,
        reason: 'the dead zone must win the hit test against the viewport',
      );
    });
  });

  group('TC-533 a resize drag tracks the pointer for its whole length', () {
    // A real pointer stream is many small moves, not one big one. Each row is
    // the SAME 60px drag, differently quantised — which is the whole point:
    // the pre-fix code was correct only for a single large delta, which is
    // exactly what `tester.drag` synthesises and why no existing test caught
    // this.
    for (final (step, steps) in [
      (4.0, 15),
      (2.0, 30),
      (1.4, 43),
      (0.6, 100),
      (0.4, 150),
    ]) {
      testWidgets('$steps moves of ${step}px == +60px', (tester) async {
        await _pump(tester, window: const Size(1440, 900));
        final gesture = await tester.startGesture(
          const Offset(kGalleryColumnMinWidth - 3, 450),
        );
        for (var i = 0; i < steps; i++) {
          await gesture.moveBy(Offset(step, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pump();

        expect(
          tester.getSize(find.byKey(kGalleryColumnSlotKey)).width,
          kGalleryColumnMinWidth + 60,
          reason:
              'a 60px drag in ${step}px steps must move the gutter exactly '
              '60px; before the fix this delivered as little as 0px',
        );
      });
    }

    testWidgets('sub-pixel deltas below 0.5px still accumulate', (tester) async {
      // The sharpest form of defect (b): every individual delta rounds to
      // zero, so a rounded accumulator can never move at all no matter how
      // long the user drags.
      await _pump(tester, window: const Size(1440, 900));
      final gesture = await tester.startGesture(
        const Offset(kGalleryColumnMinWidth - 3, 450),
      );
      for (var i = 0; i < 100; i++) {
        await gesture.moveBy(const Offset(0.3, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      expect(
        tester.getSize(find.byKey(kGalleryColumnSlotKey)).width,
        kGalleryColumnMinWidth + 30,
        reason: '100 x 0.3px == 30px, however small each individual delta is',
      );
    });
  });

  group('TC-534 the desktop Stack cannot steal the gutter slot', () {
    testWidgets('child count is identical idle and mid-drag', (tester) async {
      await _pump(tester, window: const Size(1440, 900));
      int stackChildren() => tester
          .widget<Stack>(
            find
                .descendant(
                  of: find.byType(GalleryDesktopSurface),
                  matching: find.byType(Stack),
                )
                .first,
          )
          .children
          .length;

      final idle = stackChildren();
      expect(find.byKey(kGalleryWidthBadgeKey), findsNothing);

      final gesture = await tester.startGesture(
        const Offset(kGalleryColumnMinWidth - 3, 450),
      );
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();

      // The badge is now showing, and the child count did NOT change: it took
      // a permanent slot rather than being inserted into the list.
      expect(find.byKey(kGalleryWidthBadgeKey), findsOneWidget);
      expect(
        stackChildren(),
        idle,
        reason: 'a conditional Stack child shifts every following slot and '
            'destroys the gutter element mid-gesture',
      );

      await gesture.up();
      await tester.pump();
    });

    testWidgets('the gutter slot is keyed', (tester) async {
      await _pump(tester, window: const Size(1440, 900));
      expect(find.byKey(kGalleryColumnSlotKey), findsOneWidget);
    });

    testWidgets('the gutter State survives a whole drag', (tester) async {
      await _pump(tester, window: const Size(1440, 900));
      final before = tester.state(find.byType(GalleryColumn));
      final gesture = await tester.startGesture(
        const Offset(kGalleryColumnMinWidth - 3, 450),
      );
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(2, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      // Same State instance start to finish => the element was never stolen,
      // which is the structural reason the recognizer stays alive.
      expect(identical(tester.state(find.byType(GalleryColumn)), before), isTrue);
    });
  });
}
