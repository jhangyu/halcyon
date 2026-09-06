// TC-556 — the sidebar-resize FLICKER gate.
//
// Sibling of TC-553 (gallery_thumb_anchor_test.dart) but asking a strictly
// stronger question. TC-553 measures the selected chip's viewport fraction
// only BEFORE the drag and AFTER it has settled, so it is satisfied by an
// anchor that is applied one frame LATE: every intermediate frame may be
// painted at the stale offset as long as the endpoint is right.
//
// That late correction is exactly the user-reported flicker. The mechanism:
//
//   frame N   : width changes -> `_rowExtent` grows -> the list is laid out
//               with the NEW row extent but the OLD scroll offset, so every
//               row below the top edge is displaced by `row * dExtent`
//               (~7px per row for a 10px drag step - 100px at row 15).
//   frame N+1 : the post-frame `jumpTo` lands and pulls it all back.
//
// At drag rates that alternation IS the "momentary rapid-switching frames"
// the user sees. This test therefore samples the selected chip's position on
// EVERY intermediate frame of a real multi-event drag and requires it to stay
// put throughout - which can only be satisfied by correcting the offset in
// the SAME layout pass that changes the geometry, never after it.
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

const ValueKey<String> _columnKey = ValueKey<String>(
  'gallery-column-under-test',
);

/// Owns the width state and feeds `onWidthDelta` back into it, exactly as
/// `GalleryDesktopSurface` does (T6).
class _WidthHarness extends StatefulWidget {
  const _WidthHarness({required this.initialWidth, required this.surface});

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
              key: _columnKey,
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

MainSurface _surface(List<PhotoItem> items, String selectedId) => MainSurface(
  viewport: const ColoredBox(
    key: ValueKey<String>('gallery-test-viewport'),
    color: Colors.red,
  ),
  statusOverlay: const SizedBox.shrink(),
  strip: PhotoStripModel(
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

void main() {
  testWidgets(
    'TC-556 the selected chip does not jump on ANY intermediate frame of a '
    'resize drag (no one-frame stale-offset flash)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final items = [for (var i = 0; i < 30; i++) _item('p$i')];
      const selectedId = 'p15';

      // Start inside the dragged range (>90) so the marks Column<->Wrap
      // switch at the 90px threshold cannot confound the measurement - the
      // same isolation TC-553 documents.
      await tester.pumpWidget(
        _WidthHarness(initialWidth: 100, surface: _surface(items, selectedId)),
      );
      await tester.pumpAndSettle();

      final chipKey = ValueKey<String>('gallery-chip-$selectedId');
      expect(find.byKey(chipKey), findsOneWidget);

      // Returns null when the selected chip is not built at all on this
      // frame - which is the flicker at its most extreme: the stale offset
      // pushes the row clean out of the viewport, so the frame shows a
      // completely different part of the strip before snapping back.
      // Measured against the FILMSTRIP viewport, not the whole column.
      //
      // The column-relative position also moves for a reason that is not the
      // scroll anchor: the marks row at the bottom is a `Wrap`, and as the
      // gutter widens its children reflow from two runs onto one, which
      // changes the fixed height below the strip and therefore where the
      // strip's viewport starts. That is a real, monotone layout effect
      // (TC-553 documents the same class of confound) and it is not what
      // flicker means. Anchoring is a statement about the offset WITHIN the
      // scrollable, so the scrollable is the frame of reference.
      //
      // ROUND-4 REBASE (TC-647): the measure is the chip's PIXEL distance
      // below the strip viewport's top edge, not its fraction of the viewport
      // height. The two agreed while the strip viewport had a constant height,
      // and stopped agreeing once the marks-row `Wrap` reflow was recognised
      // as a real geometry change: the strip is 590px tall at a 91px gutter
      // and 706px at 120px and above, so a chip that does not move by a single
      // pixel still reports a fraction that steps at each reflow. Pixels are
      // the thing the eye sees; the fraction was an artefact of the frame of
      // reference. (Measured under the fraction rebase: the chip held still at
      // 0.932 and 0.870 across the two plateaux — flat within each, stepping
      // only where the viewport resized.)
      double? offsetNow() {
        if (find.byKey(chipKey).evaluate().isEmpty) return null;
        final stripRect = tester.getRect(find.byType(ListView).first);
        final chipRect = tester.getRect(find.byKey(chipKey));
        return chipRect.center.dy - stripRect.top;
      }

      final start = offsetNow()!;
      // Vacuity guard: the strip must really be scrolled away from the top,
      // otherwise a stale offset has nothing to displace (`row * dExtent` is
      // zero at row 0) and the assertions below would pass for free.
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable).first).position
            .pixels,
        greaterThan(50.0),
        reason: 'the filmstrip must be scrolled for this test to mean anything',
      );
      expect(start, greaterThan(0.0));

      final topLeft = tester.getTopLeft(find.byKey(_columnKey));
      final width = tester.getSize(find.byKey(_columnKey)).width;
      final gesture = await tester.startGesture(
        Offset(topLeft.dx + width - 2.5, 300),
      );

      // Sample EVERY frame the drag produces. This is the whole point: the
      // pre-fix implementation is green on the endpoints and red here.
      final samples = <double?>[];
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump();
        samples.add(offsetNow());
      }
      await gesture.up();
      await tester.pumpAndSettle();
      samples.add(offsetNow());

      expect(
        samples.contains(null),
        isFalse,
        reason:
            'the selected chip vanished from the built range on at least one '
            'intermediate drag frame - the strip flashed to a different part '
            'of the list before the correction landed: samples=$samples',
      );

      final worst = samples
          .map((f) => (f! - start).abs())
          .reduce((a, b) => a > b ? a : b);
      expect(
        worst,
        lessThan(2.0),
        reason:
            'the selected chip flashed to a different position on at least '
            'one intermediate drag frame (stale-offset flicker): '
            'start=$start samples=$samples',
      );
    },
  );
}
