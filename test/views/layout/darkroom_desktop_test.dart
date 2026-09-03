import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_column.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_desktop.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_options_button.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_layout.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_palette.dart';
import 'package:halcyon_flutter/views/layout/layout_theme.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

/// The viewport key the geometry gate measures, matching gallery's own test
/// convention (`gallery_desktop_test.dart`).
Future<void> pumpDesktop(
  WidgetTester tester, {
  required MainSurface surface,
  Brightness brightness = Brightness.dark,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: darkroomThemeData(brightness),
      home: Scaffold(body: DarkroomDesktopSurface(surface: surface)),
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

Future<void> dragColumnTo(WidgetTester tester, double targetWidth) async {
  final current = _currentWidth(tester);
  final delta = targetWidth - current;
  if (delta == 0) return;
  final gesture = await tester.startGesture(_handlePoint(tester));
  await gesture.moveBy(Offset(delta, 0));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

Offset _handlePoint(WidgetTester tester) {
  final rect = tester.getRect(find.byKey(const ValueKey('darkroom-grip')));
  return rect.center;
}

double _currentWidth(WidgetTester tester) {
  return tester
      .getRect(find.byKey(const ValueKey('darkroom.column.slot')))
      .width;
}

void main() {
  group(
    'TC-580 the photo shrinks as the column grows (partition, never overlap)',
    () {
      // Window is 1440 wide; the photo gets exactly what the column does not.
      final expected = <double, double>{
        90.0: 1350.0,
        120.0: 1320.0,
        180.0: 1260.0,
        200.0: 1240.0,
      };
      for (final entry in expected.entries) {
        testWidgets(
          'viewport is ${entry.value.round()}x900 at column width '
          '${entry.key.round()}',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(1440, 900));
            await pumpDesktop(tester, surface: minimalSurface());

            if (entry.key > kDarkroomColumnMinWidth) {
              await dragColumnTo(tester, entry.key);
            }

            final box =
                tester.renderObject(find.byKey(kViewportKey)) as RenderBox;
            expect(box.size, Size(entry.value, 900));
            await tester.binding.setSurfaceSize(null);
          },
        );
      }
    },
  );

  group('TC-581 the column and the photo are disjoint at every width', () {
    testWidgets('column right edge never crosses the photo left edge', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      await dragColumnTo(tester, 150);

      final viewport = tester.getRect(find.byKey(kViewportKey));
      final column = tester.getRect(
        find.byKey(const ValueKey('darkroom.column.slot')),
      );
      // USER RULING R-2: the column PUSHES the photo, it never floats over it.
      expect(column.right, closeTo(150, 0.5));
      expect(viewport.left, closeTo(150, 0.5));
      expect(column.right, lessThanOrEqualTo(viewport.left + 0.5));
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-880 disjointness probe, 1px steps across the whole drag range', () {
    testWidgets('no width in [90, 200] overlaps the photo', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      final gesture = await tester.startGesture(_handlePoint(tester));
      final overlaps = <String>[];
      for (
        var width = kDarkroomColumnMinWidth + 1;
        width <= kDarkroomColumnMaxWidth;
        width += 1
      ) {
        // One logical pixel per step — finer than the 1px defect scale, so a
        // single-pixel overlap band cannot hide between samples.
        await gesture.moveBy(const Offset(1, 0));
        await tester.pump();
        final viewport = tester.getRect(find.byKey(kViewportKey));
        final column = tester.getRect(
          find.byKey(const ValueKey('darkroom.column.slot')),
        );
        if (column.right > viewport.left + 0.5) {
          overlaps.add(
            'w=${width.round()} column.right=${column.right} '
            'viewport.left=${viewport.left}',
          );
        }
      }
      await gesture.up();
      await tester.pump();

      expect(overlaps, isEmpty, reason: overlaps.join('; '));
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-881 folder and actions menu live inside the column top', () {
    testWidgets('both are descendants of DarkroomColumn, not of the cluster', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      var openFolderCalls = 0;
      final surface = minimalSurface();
      final withMenu = MainSurface(
        viewport: surface.viewport,
        statusOverlay: surface.statusOverlay,
        strip: surface.strip,
        identity: surface.identity,
        actions: PhotoActions(
          recycleMode: false,
          onStar: () {},
          onTrash: () {},
          onToggleRecycleMode: () {},
          onOpenFolder: () => openFolderCalls++,
          menu: const SizedBox(
            key: ValueKey<String>('test-menu'),
            width: 34,
            height: 34,
          ),
        ),
      );
      await pumpDesktop(tester, surface: withMenu);

      final openFolder = find.byKey(
        const ValueKey<String>('darkroom-rail-open-folder'),
      );
      expect(openFolder, findsOneWidget);
      expect(
        find.descendant(of: find.byType(DarkroomColumn), matching: openFolder),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(DarkroomColumn),
          matching: find.byKey(const ValueKey<String>('test-menu')),
        ),
        findsOneWidget,
      );

      // The rail buttons sit above the grid, inside the column's own width.
      final columnRect = tester.getRect(find.byType(DarkroomColumn));
      final buttonRect = tester.getRect(openFolder);
      expect(buttonRect.left, greaterThanOrEqualTo(columnRect.left));
      expect(buttonRect.right, lessThanOrEqualTo(columnRect.right));
      expect(
        buttonRect.bottom,
        lessThan(tester.getRect(find.byKey(
          const ValueKey<String>('darkroom-grid'),
        )).top),
      );

      await tester.tap(openFolder);
      await tester.pump();
      expect(openFolderCalls, 1);
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-882 the column bottom carries an Options gear that opens settings',
      () {
    testWidgets('the gear sits below the grid and fires its callback', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      final gear = find.byKey(
        const ValueKey<String>('darkroom-rail-options'),
      );
      expect(gear, findsOneWidget);
      expect(
        find.descendant(of: find.byType(DarkroomColumn), matching: gear),
        findsOneWidget,
      );
      final gridRect = tester.getRect(
        find.byKey(const ValueKey<String>('darkroom-grid')),
      );
      expect(tester.getRect(gear).top, greaterThanOrEqualTo(gridRect.bottom));
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('an injected callback replaces the default dialog', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: darkroomThemeData(Brightness.dark),
          home: Scaffold(
            body: DarkroomOptionsButton(onPressed: () => taps++),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('darkroom-rail-options')),
      );
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('TC-883 the verdict cluster floats top-right', () {
    testWidgets('cluster sits in the top-right corner, 24px in', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      final cluster = tester.getRect(
        find.byKey(const ValueKey<String>('darkroom-verdict')),
      );
      expect(cluster.top, closeTo(24, 0.5));
      expect(cluster.right, closeTo(1440 - 24, 0.5));
      expect(cluster.top, lessThan(900 * 0.2));
      expect(cluster.right, greaterThan(1440 * 0.8));

      // The info plan's counter is also right-anchored (right:24, bottom:20).
      // Mockup says top-right vs bottom-right are disjoint; assert it rather
      // than trust it. The finder is tolerant: before the info plan lands the
      // counter does not exist and the check is skipped.
      final counter = find.byKey(kDarkroomCounterKey);
      if (counter.evaluate().isNotEmpty) {
        final counterRect = tester.getRect(counter);
        expect(cluster.overlaps(counterRect), isFalse);
      }
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-884 the verdict cluster carries only star, trash and the key hint',
      () {
    testWidgets('key hint reads "S · X"; no folder or menu in the cluster', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      final surface = minimalSurface();
      final withMenu = MainSurface(
        viewport: surface.viewport,
        statusOverlay: surface.statusOverlay,
        strip: surface.strip,
        identity: surface.identity,
        actions: PhotoActions(
          recycleMode: false,
          onStar: () {},
          onTrash: () {},
          onToggleRecycleMode: () {},
          onOpenFolder: () {},
          menu: const SizedBox(
            key: ValueKey<String>('test-menu'),
            width: 34,
            height: 34,
          ),
        ),
      );
      await pumpDesktop(tester, surface: withMenu);

      final verdict = find.byKey(const ValueKey<String>('darkroom-verdict'));
      final hint = find.byKey(
        const ValueKey<String>('darkroom-verdict-key-hint'),
      );
      expect(hint, findsOneWidget);
      expect((tester.widget(hint) as Text).data, 'S · X');
      expect(
        find.descendant(of: verdict, matching: hint),
        findsOneWidget,
      );
      // Exactly two icon buttons in the cluster: star and trash.
      expect(
        find.descendant(of: verdict, matching: find.byType(IconButton)),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: verdict,
          matching: find.byKey(const ValueKey<String>('test-menu')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: verdict, matching: find.byIcon(Icons.folder_open)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: verdict,
          matching: find.byKey(const ValueKey<String>('darkroom-trash')),
        ),
        findsOneWidget,
      );
      await tester.binding.setSurfaceSize(null);
    });
  });

  group(
    'TC-885 the railtop row fits at the 90px floor with the real menu widget',
    () {
      testWidgets(
        'no overflow when the menu is a real 48x48 IconButton, not a stub',
        (tester) async {
          // Regression: `minimalSurface()`'s menu stub is a SizedBox(34,34),
          // which is smaller than the natural size of a real Flutter
          // IconButton/PopupMenuButton (48x48 minimum tap target, unaffected
          // by ButtonStyle.fixedSize). The stub therefore could not catch a
          // railtop row that only fits stub-sized buttons.
          await tester.binding.setSurfaceSize(const Size(1440, 900));
          final surface = minimalSurface();
          final withRealMenu = MainSurface(
            viewport: surface.viewport,
            statusOverlay: surface.statusOverlay,
            strip: surface.strip,
            identity: surface.identity,
            actions: PhotoActions(
              recycleMode: false,
              onStar: () {},
              onTrash: () {},
              onToggleRecycleMode: () {},
              onOpenFolder: () {},
              menu: PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz, size: 20),
                tooltip: 'Actions',
                padding: EdgeInsets.zero,
                itemBuilder: (context) => const [
                  PopupMenuItem<String>(value: 'a', child: Text('a')),
                ],
              ),
            ),
          );
          await pumpDesktop(tester, surface: withRealMenu);
          final caught = tester.takeException();

          expect(
            caught,
            isNull,
            reason:
                'RenderFlex overflow in the railtop row at the 90px floor: '
                '$caught',
          );
          await tester.binding.setSurfaceSize(null);
        },
      );
    },
  );

  group('TC-582 drag range clamps at 90 and 200', () {
    testWidgets('drag far left clamps to the 90 floor', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      final gesture = await tester.startGesture(_handlePoint(tester));
      await gesture.moveBy(const Offset(-300, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(_currentWidth(tester), kDarkroomColumnMinWidth);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('drag far right clamps to the 200 ceiling', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(tester, surface: minimalSurface());

      await dragColumnTo(tester, 200);
      final gesture = await tester.startGesture(_handlePoint(tester));
      await gesture.moveBy(const Offset(300, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(_currentWidth(tester), kDarkroomColumnMaxWidth);
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-583 the column is wordless: no filename, counter or labels', () {
    testWidgets('no Text widget anywhere inside DarkroomColumn', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      final items = [
        PhotoItem(id: 'a', files: const []),
        PhotoItem(id: 'b', files: const []),
      ];
      await pumpDesktop(
        tester,
        surface: minimalSurface(
          items: items,
          selectedId: 'a',
          identity: PhotoIdentity(
            displayName: 'a.jpg',
            indexInFolder: 1,
            folderCount: 2,
            status: PhotoStatus.unmarked,
            exif: null,
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(DarkroomColumn),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-584 chip grid steps per the derived table (NOTES.md)', () {
    testWidgets('one column at the 90px floor', (tester) async {
      expect(darkroomGridColumnsForWidth(90), 1);
      expect(darkroomChipWidthForColumnWidth(90), 78);
    });

    testWidgets('two columns from 180, chip steps to 84 at 192', (
      tester,
    ) async {
      expect(darkroomGridColumnsForWidth(179), 1);
      expect(darkroomGridColumnsForWidth(180), 2);
      expect(darkroomChipWidthForColumnWidth(191), 78);
      expect(darkroomChipWidthForColumnWidth(192), 84);
      expect(darkroomGridColumnsForWidth(200), 2);
      expect(darkroomChipWidthForColumnWidth(200), 84);
    });
  });

  group('TC-585 EXIF caption floats over the photo, bottom-left', () {
    testWidgets('caption sits left of center and near the bottom', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpDesktop(
        tester,
        surface: minimalSurface(
          identity: PhotoIdentity(
            displayName: 'sample.jpg',
            indexInFolder: 1,
            folderCount: 1,
            status: PhotoStatus.unmarked,
            exif: null,
          ),
        ),
      );

      final captionRect = tester.getRect(find.byType(ExifCaption));
      expect(captionRect.left, lessThan(1440 / 2));
      expect(captionRect.bottom, greaterThan(900 * 0.7));
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('TC-586 palette tokens match the approved mockup, both brightnesses', () {
    testWidgets('dark palette', (tester) async {
      const p = DarkroomPalette.dark;
      expect(p.stage, const Color(0xFF121312));
      expect(p.textFaint, const Color(0xFF67695F));
      expect(p.star, const Color(0xFFE9B84C));
      expect(p.onAccent, const Color(0xFF0C0D0C));
    });

    testWidgets('light palette', (tester) async {
      const p = DarkroomPalette.light;
      expect(p.stage, const Color(0xFFF0F2ED));
      expect(p.textFaint, const Color(0xFF93968C));
      expect(p.star, const Color(0xFFE9B84C));
      expect(p.onAccent, const Color(0xFFFFFFFF));
    });

    testWidgets('ThemeData scaffold background matches --ground', (
      tester,
    ) async {
      expect(
        darkroomThemeData(Brightness.dark).scaffoldBackgroundColor,
        const Color(0xFF0C0D0C),
      );
      expect(
        darkroomThemeData(Brightness.light).scaffoldBackgroundColor,
        const Color(0xFFE7E9E4),
      );
    });
  });

  group('TC-587 DarkroomLayout is buildable standalone, LayoutTheme-conforming', () {
    testWidgets('id, theme data and main surface all resolve', (
      tester,
    ) async {
      const layout = DarkroomLayout();
      expect(layout.id, LayoutThemeId.darkroom);
      expect(layout.themeDataFor(Brightness.dark), isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          theme: layout.themeDataFor(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: layout.buildMainSurface(context, minimalSurface()),
            ),
          ),
        ),
      );
      expect(find.byType(DarkroomDesktopSurface), findsOneWidget);
    });
  });
}
