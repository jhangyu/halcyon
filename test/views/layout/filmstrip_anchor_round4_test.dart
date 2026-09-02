// Round-4 filmstrip anchoring gates.
//
// TC-646 — the PAPER desktop strip is anchored during layout, exactly as the
//   gallery strip has been since TC-556. Round 2 shipped paper without it and
//   recorded the gap as a known limitation ("paper strip 未套 TC-556 錨定捲動");
//   this is the gate that closes it. Same shape as TC-556: sample the selected
//   chip's position on EVERY intermediate frame of a real multi-event drag.
//
// TC-647 — the marks-row `Wrap` reflow no longer moves the filmstrip.
//   The gallery gutter's five mark buttons are laid out in a `Wrap`, which
//   reflows from four runs to two as the gutter widens. That changes the fixed
//   height BELOW the strip, so the strip's own viewport grows (measured: 590px
//   of strip at a 91px gutter, 706px at 120px and above). The anchor used to
//   be expressed as a viewport FRACTION, so it faithfully re-derived a new
//   offset for the new viewport height and slid the whole strip by
//   `fraction * dViewport` — the user-reported monotone vertical shift while
//   dragging the sidebar. A pixel-distance anchor is invariant to the strip's
//   height, so a top-aligned list simply reveals more at the bottom while
//   everything already on screen stays put.
//
//   The measure here is the chip's ABSOLUTE screen position, which is what the
//   eye judges, and the sweep deliberately covers 91->130 because that is the
//   band the reflow lives in (a sweep that started above 120 would be green
//   for free — the 08-17 "unobservable resolution" false-green family).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_desktop.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';

PixelPayload _payload() =>
    PixelPayload(width: 4, height: 4, rgba: Uint8List(4 * 4 * 4));

PhotoItem _item(String id) => PhotoItem(id: id, files: [File('src/$id.jpg')]);

const ValueKey<String> _columnKey = ValueKey<String>('round4-gallery-column');

MainSurface _surface(
  List<PhotoItem> items,
  String selectedId, {
  Widget? menu,
}) => MainSurface(
  viewport: const ColoredBox(color: Colors.red),
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
    // Defaults to a real 48px IconButton, not a shrink placeholder: the marks
    // `Wrap`'s run height (and therefore the reflow TC-647 is about) depends
    // on it. The paper case overrides it — paper's 44px gutter head Row is a
    // plain `Row` that overflows at a 90px gutter when the menu is a real
    // IconButton, which is a separate paper defect (parked, round-4
    // parking-lot) and would mask the anchoring measurement here.
    menu: menu ?? IconButton(icon: const Icon(Icons.more_horiz),
        onPressed: () {}),
  ),
);

/// Owns the width state and feeds `onWidthDelta` back into it, as
/// `GalleryDesktopSurface` does.
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

void main() {
  testWidgets(
    'TC-646 the paper desktop strip re-anchors during layout: the selected '
    'chip holds still on every intermediate frame of a width drag',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final items = [for (var i = 0; i < 40; i++) _item('p$i')];
      const selectedId = 'p20';
      await tester.pumpWidget(
        MaterialApp(
          theme: paperThemeData(Brightness.light),
          home: Scaffold(
            body: PaperDesktopSurface(
              surface: _surface(
                items,
                selectedId,
                menu: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The paper strip has no "keep the selection visible" autoscroll, so
      // scroll it by hand until the selected chip is on screen AND the list is
      // genuinely away from offset 0. Without this the anchor has nothing to
      // correct (`row * dExtent` is 0 at the top) and the assertions below
      // would pass for free.
      final listFinder = find.byType(ListView).first;
      await tester.drag(listFinder, const Offset(0, -600));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(
        position.pixels,
        greaterThan(50.0),
        reason: 'the paper strip must be scrolled for this test to mean '
            'anything',
      );

      final chipKey = const ValueKey<String>('paper-chip-$selectedId');
      expect(find.byKey(chipKey), findsOneWidget);

      double? offsetNow() {
        if (find.byKey(chipKey).evaluate().isEmpty) return null;
        final stripRect = tester.getRect(find.byType(ListView).first);
        return tester.getRect(find.byKey(chipKey)).center.dy - stripRect.top;
      }

      final start = offsetNow()!;

      // Drag the gutter narrower (the paper strip's chip only scales in the
      // 40-90 band, so shrinking is where the row extent actually changes).
      // Stops at 74: paper's gutter head `Row`
      // (paper_desktop.dart:368) intrinsically needs 71px (12 + a 48px
      // IconButton + 11) and overflows at every gutter width of 70 and below.
      // That is an unrelated, pre-existing paper defect (round-4
      // parking-lot); its rendering exception would abort this measurement,
      // so the sweep stays above it.
      final gesture = await tester.startGesture(const Offset(92, 400));
      final samples = <double?>[];
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(-4, 0));
        await tester.pump();
        samples.add(offsetNow());
      }
      await gesture.up();
      await tester.pumpAndSettle();
      samples.add(offsetNow());

      expect(
        samples.contains(null),
        isFalse,
        reason: 'the selected chip left the built range on an intermediate '
            'drag frame: samples=$samples',
      );
      final worst = samples
          .map((o) => (o! - start).abs())
          .reduce((a, b) => a > b ? a : b);
      expect(
        worst,
        lessThan(2.0),
        reason: 'the paper strip jumped on an intermediate drag frame '
            '(stale-offset flicker): start=$start samples=$samples',
      );
    },
  );

  testWidgets(
    'TC-647 the marks-row Wrap reflow does not move the filmstrip: the '
    'selected chip holds its absolute position across the 91-130 band',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final items = [for (var i = 0; i < 30; i++) _item('p$i')];
      const selectedId = 'p15';
      await tester.pumpWidget(
        _WidthHarness(initialWidth: 91, surface: _surface(items, selectedId)),
      );
      await tester.pumpAndSettle();

      final chipKey = const ValueKey<String>('gallery-chip-$selectedId');
      final stripHeights = <double>{};
      double? absoluteYNow() {
        stripHeights.add(tester.getRect(find.byType(ListView).first).height);
        if (find.byKey(chipKey).evaluate().isEmpty) return null;
        return tester.getRect(find.byKey(chipKey)).center.dy;
      }

      final start = absoluteYNow()!;
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable).first).position
            .pixels,
        greaterThan(50.0),
        reason: 'the filmstrip must be scrolled for this test to mean anything',
      );

      final topLeft = tester.getTopLeft(find.byKey(_columnKey));
      final width = tester.getSize(find.byKey(_columnKey)).width;
      final gesture = await tester.startGesture(
        Offset(topLeft.dx + width - 2.5, 300),
      );
      final samples = <double?>[];
      // 1px steps across 91->130: the marks `Wrap` reflow points are single
      // widths, so a coarser step would step straight over them.
      for (var i = 0; i < 39; i++) {
        await gesture.moveBy(const Offset(1, 0));
        await tester.pump();
        samples.add(absoluteYNow());
      }
      await gesture.up();
      await tester.pumpAndSettle();

      // Instrument check: the sweep must actually have crossed a reflow, i.e.
      // the strip viewport must really have changed height during it.
      expect(
        stripHeights.length,
        greaterThan(1),
        reason: 'the marks row never reflowed across this sweep, so the test '
            'cannot observe the defect it guards: heights=$stripHeights',
      );

      expect(samples.contains(null), isFalse, reason: 'samples=$samples');
      final worst = samples
          .map((y) => (y! - start).abs())
          .reduce((a, b) => a > b ? a : b);
      expect(
        worst,
        lessThan(2.0),
        reason: 'the filmstrip shifted vertically when the marks row '
            'reflowed: start=$start heights=$stripHeights samples=$samples',
      );
    },
  );
}
