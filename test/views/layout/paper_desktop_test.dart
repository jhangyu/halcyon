// TC-564..TC-570: paper desktop geometry per
// docs/logs/2026-09-01/mockup/paper/NOTES.md ("Geometry — measured, not
// asserted" + "The sweep, 40-200 in 10px steps"). Bypasses the layout-theme
// seam (LayoutThemeId.paper does not exist yet, see task #12 handoff) and
// pumps PaperDesktopSurface directly with a hand-built MainSurface, same
// pattern as gallery_desktop_test.dart's TC-505.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart' show PhotoStatus;
import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_desktop.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';

MainSurface _emptySurface() => MainSurface(
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

  group('TC-566 chip size sweep (NOTES.md drawn points)', () {
    test('40px floor: chip scales down to 31x21', () {
      expect(paperChipWidthFor(40), 31);
      expect(paperChipHeightFor(40), 21);
    });

    test('90px default: chip pinned at 74x49', () {
      expect(paperChipWidthFor(90), 74);
      expect(paperChipHeightFor(90), closeTo(49.0, 0.01));
    });

    test('140px mid-range: chip STILL 74px (never grows with the strip)', () {
      expect(paperChipWidthFor(140), 74);
    });

    test('200px ceiling: chip STILL 74px', () {
      expect(paperChipWidthFor(200), 74);
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

  group('TC-568 layout mode sweep (NOTES.md: "Layout changes at w=91")', () {
    test('beside the photo at or below 90', () {
      expect(paperStripBeside(40), isTrue);
      expect(paperStripBeside(90), isTrue);
    });

    test('floats over the photo above 90', () {
      expect(paperStripBeside(91), isFalse);
      expect(paperStripBeside(200), isFalse);
    });
  });

  testWidgets(
      'TC-569 photo stays 1350x900 at x=90 while the strip floats at 200 (NOTES.md: '
      '"the photo has not moved")', (tester) async {
    final surface = _emptySurface();
    await _pump(tester, surface);
    // Drag the resize handle out to the ceiling.
    final handle = tester.getTopLeft(find.byKey(kPaperColumnSlotKey)) +
        const Offset(92, 50);
    final gesture = await tester.startGesture(handle);
    await gesture.moveBy(const Offset(110, 0));
    await gesture.up();
    await tester.pump();
    final rect = tester.getRect(find.byKey(kViewportKey));
    expect(rect, const Rect.fromLTWH(90, 0, 1350, 900));
  });

  testWidgets(
      'TC-566b EXIF caption is left-aligned bottom-left (mockup .overcap '
      'left:26 bottom:20, unlike gallery\'s right-aligned bottom-right)',
      (tester) async {
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
    const widths = [40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 140.0, 171.0, 200.0];
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
