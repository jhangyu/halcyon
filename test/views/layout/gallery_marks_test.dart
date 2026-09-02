// T11: equality port of photo_action_bar_test.dart:64,77 (direct/recycle
// mode icon sets), now against GalleryColumn's marks row directly. Closes
// the T7 gap ruled by team-lead against round1-plan.md lines 904-911: the
// star/trash glyphs must reflect the CURRENT item's own status (fill/color),
// not just `actions.recycleMode`. See gallery_column.dart's `_buildMarks`
// fix commit for the implementation; TC-511/512 in gallery_column_test.dart
// already cover the recycleMode-only half (icon family swap, tooltips) and
// are untouched by this file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_palette.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

const _noop = _NoopVoidCallback();

class _NoopVoidCallback {
  const _NoopVoidCallback();
  void call() {}
}

Widget _emptyMenu = const SizedBox.shrink();

MainSurface _surfaceFor({
  required PhotoStatus status,
  required bool recycleMode,
}) {
  return MainSurface(
    viewport: const ColoredBox(
      key: ValueKey<String>('gallery-test-viewport'),
      color: Colors.red,
    ),
    statusOverlay: const SizedBox.shrink(),
    strip: PhotoStripModel(
      items: const [],
      selectedId: null,
      recycleMode: recycleMode,
      onSelect: (_) {},
      payloadFor: (_) => null,
      onVisibleRange: (first, last) {},
    ),
    identity: PhotoIdentity(
      displayName: 'IMG_0001.jpg',
      indexInFolder: 1,
      folderCount: 1,
      status: status,
      exif: null,
    ),
    actions: PhotoActions(
      recycleMode: recycleMode,
      onStar: _noop.call,
      onTrash: _noop.call,
      onToggleRecycleMode: _noop.call,
      onOpenFolder: _noop.call,
      menu: _emptyMenu,
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required PhotoStatus status,
  required bool recycleMode,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 900,
            child: GalleryColumn(
              surface: _surfaceFor(status: status, recycleMode: recycleMode),
              width: 200,
              onWidthDelta: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'direct mode: an unmarked current item shows the outline trash can icon',
    (tester) async {
      await _pump(tester, status: PhotoStatus.unmarked, recycleMode: false);

      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.delete), findsNothing);
      expect(find.byIcon(Icons.restore_from_trash_outlined), findsNothing);
    },
  );

  testWidgets(
    'direct mode: a trashed current item shows the FILLED delete icon '
    '(ported from photo_action_bar_test.dart:64-75, equality preserved)',
    (tester) async {
      await _pump(tester, status: PhotoStatus.trashed, recycleMode: false);

      expect(find.byIcon(Icons.delete), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing);

      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('gallery-trash')),
          matching: find.byIcon(Icons.delete),
        ),
      );
      // photo_action_bar.dart:62 — the trashed color is red, verbatim.
      expect(icon.color, Colors.red);
    },
  );

  testWidgets(
    'recycle mode: an unmarked current item shows the outline restore icon',
    (tester) async {
      await _pump(tester, status: PhotoStatus.unmarked, recycleMode: true);

      expect(find.byIcon(Icons.restore_from_trash_outlined), findsOneWidget);
      expect(find.byIcon(Icons.restore_from_trash), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    },
  );

  testWidgets(
    'recycle mode: a trashed current item shows the FILLED restore icon '
    '(ported from photo_action_bar_test.dart:77-90, equality preserved)',
    (tester) async {
      await _pump(tester, status: PhotoStatus.trashed, recycleMode: true);

      expect(find.byIcon(Icons.restore_from_trash), findsOneWidget);
      expect(find.byIcon(Icons.restore_from_trash_outlined), findsNothing);

      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('gallery-trash')),
          matching: find.byIcon(Icons.restore_from_trash),
        ),
      );
      expect(icon.color, Colors.red);
    },
  );

  testWidgets(
    'a starred current item shows the filled star icon in GalleryPalette.star '
    '(ported equality from photo_action_bar.dart:51-52)',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 900,
                child: Builder(
                  builder: (context) {
                    return GalleryColumn(
                      surface: _surfaceFor(
                        status: PhotoStatus.starred,
                        recycleMode: false,
                      ),
                      width: 200,
                      onWidthDelta: (_) {},
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.byIcon(Icons.star_border), findsNothing);

      final context = tester.element(find.byIcon(Icons.star));
      final icon = tester.widget<Icon>(find.byIcon(Icons.star));
      expect(icon.color, GalleryPalette.of(context).star);
    },
  );

  testWidgets(
    'an unstarred current item shows the outline star icon',
    (tester) async {
      await _pump(tester, status: PhotoStatus.unmarked, recycleMode: false);
      expect(find.byIcon(Icons.star_border), findsOneWidget);
      expect(find.byIcon(Icons.star), findsNothing);
    },
  );
}
