import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_layout.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_mobile.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_mobile_empty_state.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_palette.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

/// 390 x 844 — the mobile mockup's own geometry
/// (`c2-mobile-{light,dark}.html:17`).
const Size kPhoneSize = Size(390, 844);

Future<void> pumpPhone(
  WidgetTester tester, {
  required MainSurface surface,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = kPhoneSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: darkroomThemeData(brightness),
      home: Scaffold(
        body: Builder(
          builder: (context) =>
              const DarkroomLayout().buildMobileSurface(context, surface),
        ),
      ),
    ),
  );
}

MainSurface minimalSurface({
  Widget? viewport,
  List<PhotoItem>? items,
  String? selectedId,
  PhotoIdentity? identity,
}) {
  return MainSurface(
    viewport:
        viewport ?? const ColoredBox(key: kViewportKey, color: Colors.red),
    statusOverlay: const SizedBox.shrink(),
    strip: PhotoStripModel(
      revision: ValueNotifier<int>(0),
      items: items ?? const [],
      selectedId: selectedId,
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
}

void main() {
  group('TC-640 empty folder renders the mobile welcome frame (.mwel)', () {
    testWidgets('welcome frame shown when there are no items', (
      tester,
    ) async {
      await pumpPhone(tester, surface: minimalSurface());

      expect(
        find.byType(DarkroomMobileEmptyState),
        findsOneWidget,
      );
      expect(find.text('No folder open'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('darkroom-mobile-welcome-open')),
        findsOneWidget,
      );
    });

    testWidgets('the desktop "or drop a folder" line is NOT carried over', (
      tester,
    ) async {
      await pumpPhone(tester, surface: minimalSurface());

      expect(
        find.textContaining('drop a folder onto the window'),
        findsNothing,
      );
    });

    testWidgets('the welcome button is alone on its row (no off-axis sibling)', (
      tester,
    ) async {
      await pumpPhone(tester, surface: minimalSurface());

      final buttonFinder = find.byKey(
        const ValueKey('darkroom-mobile-welcome-open'),
      );
      expect(
        find.ancestor(of: buttonFinder, matching: find.byType(Row)),
        findsNothing,
      );
    });
  });

  group('TC-641 the mobile welcome button is NOT a solid accent fill', () {
    testWidgets(
      'button background is the accent-wash token, not colorScheme.primary',
      (tester) async {
        await pumpPhone(tester, surface: minimalSurface());

        final button = tester.widget<ElevatedButton>(
          find.byKey(const ValueKey('darkroom-mobile-welcome-open')),
        );
        final resolvedBg = button.style?.backgroundColor?.resolve({});
        expect(resolvedBg, isNot(DarkroomPalette.dark.onAccent));
        expect(resolvedBg, DarkroomPalette.dark.accentWash);
      },
    );
  });

  group('TC-642 the triage frame shows a 390-wide photo and a persistent strip', () {
    testWidgets('the picture strip is present with no gesture cues at rest', (
      tester,
    ) async {
      final items = [
        PhotoItem(id: 'a', files: const []),
        PhotoItem(id: 'b', files: const []),
      ];
      await pumpPhone(
        tester,
        surface: minimalSurface(items: items, selectedId: 'a'),
      );

      expect(
        find.byKey(const ValueKey('darkroom-mobile-strip')),
        findsOneWidget,
      );
      final stripRect = tester.getRect(
        find.byKey(const ValueKey('darkroom-mobile-strip')),
      );
      expect(stripRect.height, closeTo(150, 0.5));
      // No gesture cue text/icons: round-3 scope is chrome-off-by-default,
      // no centre-tap toggle built yet.
      expect(find.byKey(const ValueKey('darkroom-mobile-tapring')), findsNothing);
    });

    testWidgets('the strip is wordless: no filename/counter text inside it', (
      tester,
    ) async {
      final items = [PhotoItem(id: 'a', files: const [])];
      await pumpPhone(
        tester,
        surface: minimalSurface(items: items, selectedId: 'a'),
      );

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('darkroom-mobile-strip')),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });

    testWidgets('the selected tile is drawn larger (78x52) than the rest (66x44)', (
      tester,
    ) async {
      final items = [
        PhotoItem(id: 'a', files: const []),
        PhotoItem(id: 'b', files: const []),
      ];
      await pumpPhone(
        tester,
        surface: minimalSurface(items: items, selectedId: 'a'),
      );

      final selectedRect = tester.getRect(
        find.byKey(const ValueKey('darkroom-mobile-tile-a')),
      );
      final unselectedRect = tester.getRect(
        find.byKey(const ValueKey('darkroom-mobile-tile-b')),
      );
      expect(selectedRect.width, closeTo(78, 0.5));
      expect(selectedRect.height, closeTo(52, 0.5));
      expect(unselectedRect.width, closeTo(66, 0.5));
      expect(unselectedRect.height, closeTo(44, 0.5));
    });
  });

  group('TC-643 EXIF caption uses the compact mobile path', () {
    testWidgets('ExifCaption is built with compact:true on mobile', (
      tester,
    ) async {
      final items = [PhotoItem(id: 'a', files: const [])];
      await pumpPhone(
        tester,
        surface: minimalSurface(
          items: items,
          selectedId: 'a',
          identity: PhotoIdentity(
            displayName: 'sample.jpg',
            indexInFolder: 1,
            folderCount: 1,
            status: PhotoStatus.unmarked,
            exif: null,
          ),
        ),
      );

      final caption = tester.widget<ExifCaption>(find.byType(ExifCaption));
      expect(caption.compact, isTrue);
    });
  });

  group('TC-644 palette matches the mobile mockup tokens (shared with desktop)', () {
    testWidgets('accent-wash token equals the welcome button fill', (
      tester,
    ) async {
      expect(DarkroomPalette.dark.accentWash, const Color(0x289BB394));
      expect(DarkroomPalette.light.accentWash, const Color(0x244C6A46));
    });
  });

  group('TC-645 DarkroomLayout.buildMobileSurface resolves per theme, both brightnesses', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('resolves for $brightness', (tester) async {
        await pumpPhone(
          tester,
          surface: minimalSurface(),
          brightness: brightness,
        );
        expect(find.byType(DarkroomMobileSurface), findsOneWidget);
      });
    }
  });
}
