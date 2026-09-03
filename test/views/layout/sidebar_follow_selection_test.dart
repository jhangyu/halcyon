// AC1 (pacer-followup-contract.md): keyboard navigation must always keep the
// selected photo visible in the sidebar/filmstrip — when the selection moves
// beyond the currently visible range, the strip must auto-scroll to bring it
// back into view.
//
// `gallery_column.dart` already implements this (`_ensureSelectedVisible`,
// wired from `initState` and from `build` whenever `strip.selectedId`
// changes). `darkroom_column.dart` and `paper_desktop.dart`'s `_PaperColumn`
// never got the equivalent wiring — they only re-anchor the selected row on
// WIDTH changes (TC-556 round 4), never on a plain selection change with a
// fixed width, which is exactly what an arrow-key press produces. This test
// simulates that: rebuild the strip with a new `selectedId` far outside the
// current scroll position, at a constant width, and assert the controller's
// scroll offset moves to bring the newly-selected chip back into the
// viewport.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_column.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_desktop.dart';

PixelPayload _payload() => PixelPayload(
  width: 4,
  height: 4,
  rgba: Uint8List(4 * 4 * 4),
);

PhotoItem _item(String id) => PhotoItem(id: id, files: [File('src/$id.jpg')]);

MainSurface _surface(List<PhotoItem> items, String? selectedId) =>
    MainSurface(
      viewport: const ColoredBox(
        key: ValueKey<String>('sidebar-follow-test-viewport'),
        color: Colors.red,
      ),
      statusOverlay: const SizedBox.shrink(),
      strip: PhotoStripModel(
        revision: ValueNotifier<int>(0),
        items: items,
        selectedId: selectedId,
        recycleMode: false,
        onSelect: (_) {},
        payloadFor: (_) => _payload(),
        onVisibleRange: (_, __) {},
      ),
      identity: const PhotoIdentity(
        displayName: 'IMG_0001.jpg',
        indexInFolder: 1,
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

/// Owns `selectedId` and rebuilds the child with a fresh [MainSurface] on
/// each change, exactly as `MainScreen` rebuilding from `AppState` would
/// after an arrow-key press moves `AppState.selectedId`.
class _SelectionHarness extends StatefulWidget {
  const _SelectionHarness({
    super.key,
    required this.items,
    required this.initialSelectedId,
    required this.builder,
  });

  final List<PhotoItem> items;
  final String initialSelectedId;
  final Widget Function(BuildContext context, MainSurface surface) builder;

  @override
  State<_SelectionHarness> createState() => _SelectionHarnessState();
}

class _SelectionHarnessState extends State<_SelectionHarness> {
  late String _selectedId = widget.initialSelectedId;

  void select(String id) => setState(() => _selectedId = id);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: widget.builder(context, _surface(widget.items, _selectedId)),
      ),
    );
  }
}

void main() {
  testWidgets(
    'DarkroomColumn auto-scrolls to keep the selection visible when it '
    'moves outside the visible range at a FIXED width (keyboard nav)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final items = [for (var i = 0; i < 40; i++) _item('p$i')];
      const columnKey = ValueKey<String>('darkroom-column-under-test');

      final harnessKey = GlobalKey<_SelectionHarnessState>();
      await tester.pumpWidget(
        _SelectionHarness(
          key: harnessKey,
          items: items,
          initialSelectedId: 'p0',
          builder: (context, surface) => Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: kDarkroomColumnMinWidth,
              height: 900,
              child: DarkroomColumn(
                key: columnKey,
                surface: surface,
                width: kDarkroomColumnMinWidth,
                onWidthDelta: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollable = find.descendant(
        of: find.byKey(columnKey),
        matching: find.byType(Scrollable),
      );
      final before = tester.state<ScrollableState>(scrollable.first).position
          .pixels;
      expect(
        before,
        equals(0.0),
        reason: 'strip should start scrolled to the top with p0 selected',
      );

      // Jump the selection far down the list — well past what a 900px-tall
      // viewport shows at this row extent — exactly what repeatedly pressing
      // the down-arrow key produces.
      harnessKey.currentState!.select('p35');
      await tester.pumpAndSettle();

      final after = tester.state<ScrollableState>(scrollable.first).position
          .pixels;
      expect(
        after,
        greaterThan(before),
        reason:
            'selecting an off-screen photo via keyboard navigation must '
            'scroll the darkroom filmstrip to bring it back into view; '
            'offset stayed at $after (started at $before)',
      );
    },
  );

  testWidgets(
    'PaperDesktopSurface auto-scrolls to keep the selection visible when it '
    'moves outside the visible range at a FIXED width (keyboard nav)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final items = [for (var i = 0; i < 40; i++) _item('p$i')];
      const surfaceKey = ValueKey<String>('paper-surface-under-test');

      final harnessKey = GlobalKey<_SelectionHarnessState>();
      await tester.pumpWidget(
        _SelectionHarness(
          key: harnessKey,
          items: items,
          initialSelectedId: 'p0',
          builder: (context, surface) =>
              PaperDesktopSurface(key: surfaceKey, surface: surface),
        ),
      );
      await tester.pumpAndSettle();

      final scrollable = find.descendant(
        of: find.byKey(surfaceKey),
        matching: find.byType(Scrollable),
      );
      final before = tester.state<ScrollableState>(scrollable.first).position
          .pixels;
      expect(
        before,
        equals(0.0),
        reason: 'strip should start scrolled to the top with p0 selected',
      );

      harnessKey.currentState!.select('p35');
      await tester.pumpAndSettle();

      final after = tester.state<ScrollableState>(scrollable.first).position
          .pixels;
      expect(
        after,
        greaterThan(before),
        reason:
            'selecting an off-screen photo via keyboard navigation must '
            'scroll the paper filmstrip to bring it back into view; '
            'offset stayed at $after (started at $before)',
      );
    },
  );
}
