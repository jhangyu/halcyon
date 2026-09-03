// TC-564..TC-570: paper desktop geometry per
// docs/logs/2026-09-01/mockup/paper/NOTES.md ("Geometry — measured, not
// asserted" + "The sweep, 40-200 in 10px steps"). Bypasses the layout-theme
// seam (LayoutThemeId.paper does not exist yet, see task #12 handoff) and
// pumps PaperDesktopSurface directly with a hand-built MainSurface, same
// pattern as gallery_desktop_test.dart's TC-505.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_desktop.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';

MainSurface _emptySurface() => MainSurface(
      viewport: const ColoredBox(key: kViewportKey, color: Colors.red),
      statusOverlay: const SizedBox.shrink(),
      strip: PhotoStripModel(
        revision: ValueNotifier<int>(0),
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

PixelPayload _payload() =>
    PixelPayload(width: 4, height: 4, rgba: Uint8List(4 * 4 * 4));

const PhotoIdentity _identity = PhotoIdentity(
  displayName: 'DSCF4417.RAF',
  indexInFolder: 34,
  folderCount: 212,
  status: PhotoStatus.unmarked,
  exif: ExifMetadata(camera: 'FUJIFILM X-T5', iso: 320),
);

/// A surface with [count] items and a caption-bearing identity — the fixture
/// the layout gates need (an empty surface renders a zero-size ExifCaption,
/// which would make a disjointness assertion pass for free).
MainSurface _loadedSurface(int count) => MainSurface(
      viewport: const ColoredBox(key: kViewportKey, color: Colors.red),
      statusOverlay: const SizedBox.shrink(),
      strip: PhotoStripModel(
        revision: ValueNotifier<int>(0),
        items: [
          for (var i = 0; i < count; i++)
            PhotoItem(id: 'p$i', files: [File('src/p$i.jpg')]),
        ],
        selectedId: 'p0',
        recycleMode: false,
        onSelect: (_) {},
        payloadFor: (_) => _payload(),
        onVisibleRange: (_, __) {},
      ),
      identity: _identity,
      actions: PhotoActions(
        recycleMode: false,
        onStar: () {},
        onTrash: () {},
        onToggleRecycleMode: () {},
        onOpenFolder: () {},
        menu: const SizedBox.shrink(),
      ),
    );

/// Asserts the painted strip, the preview and the caption occupy disjoint
/// horizontal regions. Touching edges are allowed; overlap is not.
void _expectDisjoint(WidgetTester tester) {
  final strip = tester.getRect(find.byKey(kPaperColumnSlotKey));
  final photo = tester.getRect(find.byKey(kViewportKey));
  final caption = tester.getRect(find.byType(ExifCaption));
  expect(
    photo.left,
    greaterThanOrEqualTo(strip.right - 0.01),
    reason: 'preview starts inside the strip at gutter width ${strip.width}',
  );
  expect(
    caption.left,
    greaterThanOrEqualTo(strip.right - 0.01),
    reason: 'caption starts inside the strip at gutter width ${strip.width}',
  );
}

Future<void> _pump(WidgetTester tester, MainSurface surface) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: paperThemeData(Brightness.light),
      home: Scaffold(body: PaperDesktopSurface(surface: surface)),
    ),
  );
}

void main() {
  testWidgets(
      'TC-564 photo is 1350x900 at x=90 at rest (mockup: photo=1350x900 atX=90 atY=0)',
      (tester) async {
    await _pump(tester, _emptySurface());
    final rect = tester.getRect(find.byKey(kViewportKey));
    expect(rect, const Rect.fromLTWH(90, 0, 1350, 900));
  });

  testWidgets(
      'TC-565 gutter slot is 90px wide at rest (mockup: 90px column beside the photo)',
      (tester) async {
    await _pump(tester, _emptySurface());
    final size = tester.getSize(find.byKey(kPaperColumnSlotKey));
    expect(size.width, 90);
  });

  group(
      'TC-566 chip size sweep (USER RULING R-1: continuous scaling — the chip '
      'GROWS with the strip, overriding the mockup\'s pinned 74x49)', () {
    test('40px floor: chip scales down to 31x21 (mockup frame 3)', () {
      expect(paperChipWidthFor(40), 31);
      expect(paperChipHeightFor(40), 21);
    });

    test('90px rest: chip is 74x49 (mockup frame 4)', () {
      expect(paperChipWidthFor(90), 74);
      expect(paperChipHeightFor(90), closeTo(49.0, 0.01));
    });

    test('140px mid-range: the chip GROWS with the strip (R-1)', () {
      expect(paperChipWidthFor(140), greaterThan(paperChipWidthFor(90)));
      expect(paperChipWidthFor(140), 124);
    });

    test('the one-column curve is continuous across the 90 seam', () {
      expect(paperChipWidthFor(89.999), closeTo(paperChipWidthFor(90), 0.05));
      expect(paperChipHeightFor(89.999), closeTo(paperChipHeightFor(90), 0.05));
    });

    test('entering the two-column band never shrinks a chip below rest', () {
      expect(paperChipWidthFor(171), 74);
      expect(paperChipWidthFor(200), closeTo(88.5, 0.01));
    });

    test('grid padding is 8 at and above rest, and shrinks below it', () {
      expect(paperGridPaddingFor(90), 8);
      expect(paperGridPaddingFor(140), 8);
      expect(paperGridPaddingFor(171), 8);
      expect(paperGridPaddingFor(200), 8);
      expect(paperGridPaddingFor(40), closeTo(4.5, 0.01));
    });

    test('the row extent tracks the chip height', () {
      expect(paperRowExtentFor(90), closeTo(49.0 + kPaperStripGap, 0.01));
      expect(paperRowExtentFor(140), closeTo(124 / (74 / 49) + kPaperStripGap, 0.01));
    });

    test('the grid aspect matches the rendered chip at both ends', () {
      expect(paperChipAspectFor(40), closeTo(31 / 21, 0.001));
      expect(paperChipAspectFor(140), closeTo(74 / 49, 0.001));
    });
  });

  group('TC-567 column count sweep (NOTES.md: "changes exactly once, at w=171")', () {
    test('one column below 171', () {
      expect(paperColumnsFor(90), 1);
      expect(paperColumnsFor(140), 1);
      expect(paperColumnsFor(170), 1);
    });

    test('two columns at and above 171', () {
      expect(paperColumnsFor(171), 2);
      expect(paperColumnsFor(200), 2);
    });
  });

  testWidgets(
      'TC-569 the photo tracks the gutter: 1350x900 at x=90 at rest, and '
      'exactly (1440 - gutter) wide once dragged (R-2)', (tester) async {
    await _pump(tester, _loadedSurface(6));
    expect(
      tester.getRect(find.byKey(kViewportKey)),
      const Rect.fromLTWH(90, 0, 1350, 900),
    );
    final gesture = await tester.startGesture(const Offset(92, 400));
    await gesture.moveBy(const Offset(110, 0)); // 90 -> 200
    await gesture.up();
    await tester.pump();
    expect(
      tester.getRect(find.byKey(kViewportKey)),
      const Rect.fromLTWH(200, 0, 1240, 900),
    );
  });

  testWidgets(
      'TC-865 strip, preview and caption stay disjoint at EVERY gutter width '
      '(1px sweep, 74..200) — USER RULING R-2, no float-over', (tester) async {
    await _pump(tester, _loadedSurface(40));
    _expectDisjoint(tester);
    // The handle sits at [_width, _width+6); at rest that is [90, 96).
    final gesture = await tester.startGesture(const Offset(92, 400));
    // Down to 74 first. 74 is the floor of this sweep, NOT 40: `_buildHead`'s
    // Row intrinsically needs 71px and throws a render overflow at gutter
    // widths <= 70 (a pre-existing round-4 parking-lot defect, see
    // test/views/layout/filmstrip_anchor_round4_test.dart). A render exception
    // would abort the measurement rather than fail an assertion.
    for (var i = 0; i < 16; i++) {
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      _expectDisjoint(tester);
    }
    // ...then all the way up to the 200 ceiling. 1px steps, not 10px: the
    // historical defect appeared the pixel the strip passed the caption's
    // left edge, and a coarse scan step has walked over a live defect in this
    // repo before (lessons-learned 2026-09-02).
    for (var i = 0; i < 126; i++) {
      await gesture.moveBy(const Offset(1, 0));
      await tester.pump();
      _expectDisjoint(tester);
    }
    expect(tester.getSize(find.byKey(kPaperColumnSlotKey)).width, 200);
    await gesture.up();
    await tester.pump();
  });

  testWidgets(
      'TC-866 widening the gutter SHRINKS the preview (R-2 overrides the '
      'mockup\'s "it floats over it and never pushes it")', (tester) async {
    await _pump(tester, _loadedSurface(6));
    final gesture = await tester.startGesture(const Offset(92, 400));
    await gesture.moveBy(const Offset(200, 0)); // clamps at the 200 ceiling
    await gesture.up();
    await tester.pump();
    expect(tester.getSize(find.byKey(kPaperColumnSlotKey)).width, 200);
    expect(
      tester.getRect(find.byKey(kViewportKey)),
      const Rect.fromLTWH(200, 0, 1240, 900),
    );
  });

  testWidgets('TC-867 two chips render SIDE BY SIDE at gutter width 200',
      (tester) async {
    await _pump(tester, _loadedSurface(6));
    final gesture = await tester.startGesture(const Offset(92, 400));
    await gesture.moveBy(const Offset(200, 0));
    await gesture.up();
    await tester.pump();
    final a = tester.getRect(find.byKey(const ValueKey<String>('paper-chip-p0')));
    final b = tester.getRect(find.byKey(const ValueKey<String>('paper-chip-p1')));
    expect(a.top, closeTo(b.top, 0.5),
        reason: 'the first two chips must share one row');
    expect(b.left, greaterThan(a.right - 0.5),
        reason: 'the second chip must sit to the RIGHT of the first');
    expect(a.width, closeTo(88.5, 1.0),
        reason: 'a two-column chip at w=200 is (200 - 16 - 7) / 2');
  });

  testWidgets('TC-868 the RENDERED chip grows with the gutter (R-1)',
      (tester) async {
    await _pump(tester, _loadedSurface(6));
    final chip = find.byKey(const ValueKey<String>('paper-chip-p0'));
    final atRest = tester.getSize(chip).width;
    final gesture = await tester.startGesture(const Offset(92, 400));
    await gesture.moveBy(const Offset(50, 0)); // 90 -> 140
    await gesture.up();
    await tester.pump();
    final at140 = tester.getSize(chip).width;
    expect(atRest, closeTo(74, 1.0));
    expect(at140, greaterThan(atRest));
    expect(at140, closeTo(124, 1.0), reason: '140 - 2 * kPaperGridPadding');
  });

  testWidgets(
      'TC-566b EXIF caption is left-aligned bottom-left (mockup .overcap '
      'left:26 bottom:20, unlike gallery\'s right-aligned bottom-right)',
      (tester) async {
    final surface = MainSurface(
      viewport: const ColoredBox(key: kViewportKey, color: Colors.red),
      statusOverlay: const SizedBox.shrink(),
      strip: PhotoStripModel(
        revision: ValueNotifier<int>(0),
        items: const [],
        selectedId: null,
        recycleMode: false,
        onSelect: (_) {},
        payloadFor: (_) => null,
        onVisibleRange: (_, __) {},
      ),
      identity: const PhotoIdentity(
        displayName: 'DSCF4417.RAF',
        indexInFolder: 34,
        folderCount: 212,
        status: PhotoStatus.unmarked,
        exif: ExifMetadata(camera: 'FUJIFILM X-T5', iso: 320),
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
    await _pump(tester, surface);
    final caption = tester.widget<ExifCaption>(find.byType(ExifCaption));
    expect(caption.alignment, CrossAxisAlignment.start);
    // Positioned bottom-left over the photo, not bottom-right.
    final captionRect = tester.getRect(find.byType(ExifCaption));
    final photoRect = tester.getRect(find.byKey(kViewportKey));
    expect(captionRect.left, closeTo(photoRect.left + 26, 1.0));
  });

  testWidgets('TC-570 no-width-worse-on-both-axes holds across the drawn sweep',
      (tester) async {
    // NOTES.md invariant: "No width may be worse than a narrower width on
    // BOTH axes at once." Checked on the widths this file actually samples.
    const widths = [
      40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 140.0, 170.0, 171.0, 200.0,
    ];
    for (var i = 1; i < widths.length; i++) {
      final prevChip = paperChipWidthFor(widths[i - 1]);
      final curChip = paperChipWidthFor(widths[i]);
      final prevCols = paperColumnsFor(widths[i - 1]);
      final curCols = paperColumnsFor(widths[i]);
      // Forbidden: fewer/smaller on chip AND fewer columns at a wider width.
      final worseChip = curChip < prevChip;
      final worseCols = curCols < prevCols;
      expect(
        worseChip && worseCols,
        isFalse,
        reason:
            'width ${widths[i]} must not be worse than ${widths[i - 1]} on both axes',
      );
    }
  });
}
