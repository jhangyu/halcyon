// TC-863: darkroom's `.counter` block (mockup
// docs/logs/2026-09-01/mockup/darkroom/c2-desktop-dark.html CSS :218-224,
// markup :453-456) and the joined caption (`.caption`, CSS :210-217, markup
// :449-452). Pumps DarkroomDesktopSurface directly, same pattern as
// darkroom_desktop_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart' show PhotoStatus;
import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_desktop.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_palette.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

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
  displayName: '_DSF4187.RAF',
  indexInFolder: 37,
  folderCount: 412,
  status: PhotoStatus.unmarked,
  exif: ExifMetadata(
    camera: 'FUJIFILM X-T5',
    focalLength: 35,
    aperture: 2,
    shutter: '1/500 s',
    iso: 320,
  ),
  starredCount: 61,
  trashedCount: 18,
);

Future<void> _pump(WidgetTester tester, MainSurface surface) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: darkroomThemeData(Brightness.dark),
      home: Scaffold(body: DarkroomDesktopSurface(surface: surface)),
    ),
  );
}

void main() {
  group('TC-863 darkroom .counter block', () {
    testWidgets('draws "<b>37</b> / 412" over "61 starred · 18 marked"',
        (tester) async {
      await _pump(tester, _surface(identity: _identity));
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == '37 / 412',
        ),
        findsOneWidget,
      );
      expect(find.text('61 starred · 18 marked'), findsOneWidget);
    });

    testWidgets('sits 24px from the right edge, 20px from the bottom',
        (tester) async {
      await _pump(tester, _surface(identity: _identity));
      final rect = tester.getRect(find.byKey(kDarkroomCounterKey));
      expect(rect.right, closeTo(1440 - 24, 1.0));
      expect(rect.bottom, closeTo(900 - 20, 1.0));
    });

    testWidgets('draws the marked line even when both counts are zero',
        (tester) async {
      await _pump(
        tester,
        _surface(
          identity: const PhotoIdentity(
            displayName: '_DSF4187.RAF',
            indexInFolder: 1,
            folderCount: 5,
            status: PhotoStatus.unmarked,
            exif: null,
          ),
        ),
      );
      expect(find.text('0 starred · 0 marked'), findsOneWidget);
    });

    testWidgets('renders nothing when no folder is loaded', (tester) async {
      await _pump(tester, _surface());
      expect(find.byKey(kDarkroomCounterKey), findsNothing);
    });
  });

  group('TC-863 darkroom caption uses the joined variant', () {
    testWidgets('joined variant, 13px title, 11px EXIF line, no rule',
        (tester) async {
      await _pump(tester, _surface(identity: _identity));
      final caption = tester.widget<ExifCaption>(find.byType(ExifCaption));
      expect(caption.variant, ExifCaptionVariant.joined);
      expect(caption.alignment, CrossAxisAlignment.start);
      expect(caption.titleStyle!.fontSize, 13);
      expect(caption.detailStyle!.fontSize, 11);
      expect(caption.detailGap, 4);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container &&
              w.margin == const EdgeInsets.only(top: 4, bottom: 3),
        ),
        findsNothing,
        reason: 'darkroom\'s mockup draws no hairline rule',
      );
      expect(
        find.text('FUJIFILM X-T5 · 35 mm · ƒ/2 · 1/500 s · ISO 320'),
        findsOneWidget,
      );
    });
  });
}
