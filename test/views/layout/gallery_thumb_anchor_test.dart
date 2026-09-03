// R1-2 (parking-lot, handover §8): dragging the sidebar wider/narrower
// changes `_rowExtent` (the chip scales with the gutter — TC-543), which
// remaps every row's pixel position under a FIXED ScrollController offset.
// Symptom: the strip visibly scrolls away from the currently-viewed photo
// mid-drag. This proves the currently-selected chip stays at (approximately)
// the same FRACTION of the viewport across a width change driven by a real
// multi-event drag gesture on the resize handle.
//
// Per the handover's refuted-hypothesis table (§7): a single-event
// `tester.drag` is structurally blind to this class of bug (it was blind to
// the resize-handle-death bug for the same reason — the widget never sees
// intermediate frames). This test drives `startGesture` + `moveBy` instead,
// applying the reported deltas to a width `setState` exactly as
// `GalleryDesktopSurface` does in production, so `didUpdateWidget` fires on
// every intermediate frame the way a real drag produces it.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

PixelPayload _payload() => PixelPayload(
  width: 4,
  height: 4,
  rgba: Uint8List(4 * 4 * 4),
);

PhotoItem _item(String id) => PhotoItem(id: id, files: [File('src/$id.jpg')]);

/// A harness that owns the width `State` itself and feeds `onWidthDelta`
/// straight back into it, the same pattern `GalleryDesktopSurface` uses in
/// production (T6: "a horizontal drag reports the raw pointer delta; the
/// parent owns the clamping arithmetic and the width state").
class _WidthHarness extends StatefulWidget {
  const _WidthHarness({
    required this.initialWidth,
    required this.surface,
  });

  final double initialWidth;
  final MainSurface surface;

  @override
  State<_WidthHarness> createState() => _WidthHarnessState();
}

class _WidthHarnessState extends State<_WidthHarness> {
  late double _width = widget.initialWidth;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _width,
            height: 900,
            child: GalleryColumn(
              key: const ValueKey<String>('gallery-column-under-test'),
              surface: widget.surface,
              width: _width,
              onWidthDelta: (dx) => setState(() {
                _width = (_width + dx).clamp(90.0, 200.0);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'TC-553 the selected chip stays at the same viewport fraction across a '
    'real multi-event drag',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      final items = [for (var i = 0; i < 30; i++) _item('p$i')];
      // Pick a selected item deep enough in the list that at rest (90px
      // gutter) it sits below the fold, so a real scroll offset is
      // established before the drag begins — an anchor bug is invisible at
      // offset 0.
      const selectedId = 'p15';

      final surface = MainSurface(
        viewport: const ColoredBox(
          key: ValueKey<String>('gallery-test-viewport'),
          color: Colors.red,
        ),
        statusOverlay: const SizedBox.shrink(),
        strip: PhotoStripModel(
          revision: ValueNotifier<int>(0),
          items: items,
          selectedId: selectedId,
          recycleMode: false,
          onSelect: (_) {},
          payloadFor: (_) => _payload(),
          onVisibleRange: (_, __) {},
        ),
        identity: const PhotoIdentity(
          displayName: 'IMG_0001.jpg',
          indexInFolder: 16,
          folderCount: 30,
          status: PhotoStatus.unmarked,
          exif: null,
        ),
        actions: PhotoActions(
          recycleMode: false,
          onStar: () {},
          onTrash: () {},
          onToggleRecycleMode: () {},
          onOpenFolder: () {},
          menu: const SizedBox.shrink(),
        ),
      );

      // Start already past the 90px "dragged" threshold (`_dragged` in
      // gallery_column.dart), not AT it: crossing that threshold flips the
      // marks row from a vertical Column to a horizontal Wrap
      // (`_buildMarks`), which reserves a very different fixed height at the
      // bottom of the gutter and would itself move the filmstrip's viewport
      // — a real, separate layout effect, not the scroll-anchor bug this
      // test targets. Starting inside the dragged range isolates the
      // anchor math from that confound while still exercising the same
      // chip-height-driven `_rowExtent` growth the bug is about.
      await tester.pumpWidget(
        _WidthHarness(initialWidth: 100, surface: surface),
      );
      // Let the initial post-frame `_ensureSelectedVisible` autoscroll settle.
      await tester.pumpAndSettle();

      final chipKey = ValueKey<String>('gallery-chip-$selectedId');
      expect(find.byKey(chipKey), findsOneWidget);

      final columnRectBefore = tester.getRect(
        find.byKey(const ValueKey<String>('gallery-column-under-test')),
      );
      final chipRectBefore = tester.getRect(find.byKey(chipKey));
      final fractionBefore =
          (chipRectBefore.center.dy - columnRectBefore.top) /
          columnRectBefore.height;
      // Sanity: the item really is scrolled to somewhere mid-viewport, not
      // sitting at the top edge by coincidence (which would make the
      // anchoring assertion vacuous).
      expect(fractionBefore, greaterThan(0.05));
      expect(fractionBefore, lessThan(0.95));

      // Real multi-event drag on the resize handle: widen the gutter from
      // 90 to 200 over several intermediate frames, exactly like TC-513's
      // drag but applied here through the width-owning harness so
      // `didUpdateWidget` actually fires per frame, the way production does.
      final topLeft = tester.getTopLeft(
        find.byKey(const ValueKey<String>('gallery-column-under-test')),
      );
      final width = tester
          .getSize(
            find.byKey(const ValueKey<String>('gallery-column-under-test')),
          )
          .width;
      final handleX = topLeft.dx + width - 2.5;
      final gesture = await tester.startGesture(Offset(handleX, 300));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      // Let the post-frame anchor jump (scheduled from didUpdateWidget) run.
      await tester.pump();
      await tester.pump();

      final columnRectAfter = tester.getRect(
        find.byKey(const ValueKey<String>('gallery-column-under-test')),
      );
      expect(
        columnRectAfter.width,
        closeTo(200, 0.5),
        reason: 'drag should have widened the gutter to the 200px ceiling',
      );

      final chipRectAfter = tester.getRect(find.byKey(chipKey));
      final fractionAfter =
          (chipRectAfter.center.dy - columnRectAfter.top) /
          columnRectAfter.height;

      expect(
        fractionAfter,
        closeTo(fractionBefore, 0.08),
        reason:
            'the currently-viewed photo drifted out of its relative '
            'position: before=$fractionBefore after=$fractionAfter '
            '(chip before=$chipRectBefore after=$chipRectAfter)',
      );

      await tester.binding.setSurfaceSize(null);
    },
  );
}
