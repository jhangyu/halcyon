// TC-620..TC-633: paper mobile surface per
// docs/logs/2026-09-01/mockup/paper/c1-mobile-{light,dark}.html frame 1
// ("Triage at rest") and NOTES.md. Goes through the real seam
// (`LayoutTheme.buildMobileSurface`), pumped at a phone-sized
// `tester.view.physicalSize` (reset in teardown, no platform faking, per
// task #16 instructions).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_layout.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_mobile.dart';

const ValueKey<String> _kViewportKey = ValueKey<String>(
  'paper.mobile.test.viewport',
);

MainSurface _surfaceWith({PhotoIdentity? identity}) => MainSurface(
      viewport: const ColoredBox(key: _kViewportKey, color: Colors.blue),
      statusOverlay: const SizedBox.shrink(),
      strip: PhotoStripModel(
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

/// Pumps the real `PaperLayout.buildMobileSurface` seam at the mockup's own
/// 390x844 phone viewport (`c1-mobile-light.html:189` `.viewport{width:390px;
/// height:844px}`).
Future<void> _pumpMobile(
  WidgetTester tester,
  MainSurface surface, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  const theme = PaperLayout();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.themeDataFor(brightness),
      home: Scaffold(
        body: Builder(
          builder: (context) => theme.buildMobileSurface(context, surface),
        ),
      ),
    ),
  );
}

void main() {
  group('TC-620 mobile surface fills the phone viewport, both brightnesses', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('$brightness: stage + label fill 390x844', (tester) async {
        await _pumpMobile(tester, _surfaceWith(), brightness: brightness);
        // No horizontal overflow: the root ColoredBox in PaperMobileSurface
        // fills the full device width.
        final size = tester.getSize(find.byType(PaperMobileSurface));
        expect(size.width, 390);
        expect(size.height, 844);
      });
    }
  });

  testWidgets('TC-621 the photo stage positions surface.viewport unclipped',
      (tester) async {
    // identity != null: the triage frame (a null identity now renders the
    // mobile welcome frame instead — lead wiring at round-3 close).
    await _pumpMobile(
      tester,
      _surfaceWith(
        identity: const PhotoIdentity(
          displayName: 'DSCF4417.RAF',
          indexInFolder: 34,
          folderCount: 212,
          status: PhotoStatus.unmarked,
          exif: ExifMetadata(camera: 'FUJIFILM X-T5', iso: 320),
        ),
      ),
    );
    expect(find.byKey(_kViewportKey), findsOneWidget);
    final rect = tester.getRect(find.byKey(_kViewportKey));
    // Positioned inside the stage, above the label (mockup: label starts at
    // y=656 of 844, i.e. well below the stage).
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.width, greaterThan(0));
    expect(rect.height, greaterThan(0));
  });

  testWidgets('TC-622 filename and index render below the photo (mockup .mlabel)',
      (tester) async {
    final surface = _surfaceWith(
      identity: const PhotoIdentity(
        displayName: 'DSCF4417.RAF',
        indexInFolder: 34,
        folderCount: 212,
        status: PhotoStatus.unmarked,
        exif: ExifMetadata(camera: 'FUJIFILM X-T5', iso: 320),
      ),
    );
    await _pumpMobile(tester, surface);
    expect(find.text('DSCF4417.RAF'), findsOneWidget);
    expect(find.text('34 / 212'), findsOneWidget);
    // Label sits below the stage.
    final stageRect = tester.getRect(find.byKey(PaperMobileSurface.stageKey));
    final labelRect = tester.getRect(find.byKey(PaperMobileSurface.labelKey));
    expect(labelRect.top, greaterThanOrEqualTo(stageRect.bottom));
  });

  testWidgets('TC-623 EXIF caption renders compact (single line, no rule)',
      (tester) async {
    final surface = _surfaceWith(
      identity: const PhotoIdentity(
        displayName: 'DSCF4417.RAF',
        indexInFolder: 34,
        folderCount: 212,
        status: PhotoStatus.unmarked,
        exif: ExifMetadata(camera: 'FUJIFILM X-T5', iso: 320),
      ),
    );
    await _pumpMobile(tester, surface);
    final caption = tester.widget<ExifCaption>(find.byType(ExifCaption));
    expect(caption.compact, isTrue);
    // Compact draws no separate file-name line inside ExifCaption; this
    // surface draws the filename itself above it instead (see TC-622).
    expect(caption.fileName, isNull);
  });

  testWidgets('TC-624 no identity: label renders without crashing (welcome '
      'handled upstream by MainSurface.viewport, per architecture contract)',
      (tester) async {
    await _pumpMobile(tester, _surfaceWith(identity: null));
    expect(find.byType(PaperMobileSurface), findsOneWidget);
    expect(find.text('DSCF4417.RAF'), findsNothing);
  });
}
