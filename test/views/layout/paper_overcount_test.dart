// TC-862 (caption) / TC-864 (over-count): paper's `.overcap` and `.overcount`
// (mockup docs/logs/2026-09-01/mockup/paper/c1-desktop-dark.html CSS :246-251,
// markup :443). Pumps PaperDesktopSurface directly, same pattern as
// paper_desktop_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart' show PhotoStatus;
import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_desktop.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';

MainSurface _surface({PhotoIdentity? identity}) => MainSurface(
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
      identity: identity,
      actions: PhotoActions(
        recycleMode: false,
        onStar: () {},
        onTrash: () {},
        onToggleRecycleMode: () {},
        onOpenFolder: () {},
        menu: const SizedBox.shrink(),
      ),
    );

const PhotoIdentity _identity = PhotoIdentity(
  displayName: 'DSCF4417.RAF',
  indexInFolder: 34,
  folderCount: 212,
  status: PhotoStatus.unmarked,
  exif: ExifMetadata(
    camera: 'FUJIFILM X-T5',
    focalLength: 23,
    aperture: 4,
    shutter: '1/500 s',
    iso: 320,
  ),
  starredCount: 18,
  trashedCount: 3,
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
  group('TC-864 paper .overcount carries the starred segment', () {
    testWidgets('reads "34 / 212 · 18 starred" in serif', (tester) async {
      await _pump(tester, _surface(identity: _identity));
      expect(find.text('34 / 212 · 18 starred'), findsOneWidget);
      final text = tester.widget<Text>(find.byKey(kPaperOverCountKey));
      expect(text.style!.fontFamily, 'serif');
      expect(text.style!.fontSize, 13);
    });

    testWidgets('keeps the segment at zero starred', (tester) async {
      await _pump(
        tester,
        _surface(
          identity: const PhotoIdentity(
            displayName: 'DSCF4417.RAF',
            indexInFolder: 1,
            folderCount: 5,
            status: PhotoStatus.unmarked,
            exif: null,
          ),
        ),
      );
      expect(find.text('1 / 5 · 0 starred'), findsOneWidget);
    });

    testWidgets('renders nothing when no folder is loaded', (tester) async {
      await _pump(tester, _surface());
      expect(find.byKey(kPaperOverCountKey), findsNothing);
    });

    testWidgets('the strip-footer tally is untouched', (tester) async {
      await _pump(tester, _surface(identity: _identity));
      expect(find.text('34 / 212'), findsOneWidget,
          reason: 'the .tally in the gutter still shows progress only');
    });
  });

  group('TC-862 paper .overcap is a serif, joined, rule-less caption', () {
    testWidgets('joined variant with a 15px serif title line', (tester) async {
      await _pump(tester, _surface(identity: _identity));
      final caption = tester.widget<ExifCaption>(find.byType(ExifCaption));
      expect(caption.variant, ExifCaptionVariant.joined);
      expect(caption.alignment, CrossAxisAlignment.start);
      expect(caption.titleStyle!.fontFamily, 'serif');
      expect(caption.titleStyle!.fontSize, 15);
      expect(caption.detailStyle!.fontSize, 11);
      expect(caption.detailGap, 5);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container &&
              w.margin == const EdgeInsets.only(top: 4, bottom: 3),
        ),
        findsNothing,
        reason: 'paper\'s mockup draws no hairline rule',
      );
      expect(
        find.text('FUJIFILM X-T5 · 23 mm · ƒ/4 · 1/500 s · ISO 320'),
        findsOneWidget,
      );
    });
  });
}
