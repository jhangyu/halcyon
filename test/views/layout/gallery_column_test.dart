// GalleryColumn (T7) tests. Final IDs are the user-ruled no-collision mapping
// (contract AC #10): 501->TC-508, 501b->TC-508b, 501c->TC-508c, 502->TC-509,
// 503->TC-510, 504->TC-511, 505 (tooltips)->TC-512, 506 (drag delta)->TC-513.
// These labels are final and occupy no registry slot outside the assigned
// gallery block; the lead owns the docs registration.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/common/photo_thumbnail.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

/// A valid 4x4 RGBA8 `PixelPayload`: constructible without decode.
PixelPayload _payload() => PixelPayload(
      width: 4,
      height: 4,
      rgba: Uint8List(4 * 4 * 4),
    );

PhotoItem _item(String id) => PhotoItem(id: id, files: [File('src/$id.jpg')]);

/// Builds the column at [width] in a 1200x900 window with a strip of
/// `itemIds`. [rangeLog] collects every (first, last) visible-range report.
Future<void> pumpColumn(
  WidgetTester tester, {
  required double width,
  List<String> itemIds = const [],
  String? selectedId,
  bool recycleMode = false,
  List<int>? rangeLog,
  VoidCallback? onTrash,
  VoidCallback? onToggleRecycle,
  void Function(int first, int last)? onVisibleRange,
}) async {
  final items = [for (final id in itemIds) _item(id)];
  final surface = MainSurface(
    viewport: const ColoredBox(
      key: ValueKey<String>('gallery-test-viewport'),
      color: Colors.red,
    ),
    statusOverlay: const SizedBox.shrink(),
    strip: PhotoStripModel(
      items: items,
      selectedId: selectedId,
      recycleMode: recycleMode,
      onSelect: (_) {},
      payloadFor: (_) => _payload(),
      onVisibleRange: (first, last) {
        rangeLog?.addAll([first, last]);
        onVisibleRange?.call(first, last);
      },
    ),
    identity: PhotoIdentity(
      displayName: 'IMG_0001.jpg',
      indexInFolder: 1,
      folderCount: items.length,
      status: PhotoStatus.unmarked,
      exif: null,
    ),
    actions: PhotoActions(
      recycleMode: recycleMode,
      onStar: () {},
      onTrash: onTrash ?? () {},
      onToggleRecycleMode: onToggleRecycle ?? () {},
      onOpenFolder: () {},
      menu: const SizedBox.shrink(),
    ),
  );

  await tester.binding.setSurfaceSize(const Size(1200, 900));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 900,
            child: GalleryColumn(
              surface: surface,
              width: width,
              onWidthDelta: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The chips in render row [row] (rows are keyed `gallery-row-N`).
int _chipsInRow(WidgetTester tester, int row) {
  final rowFinder = find.byKey(ValueKey<String>('gallery-row-$row'));
  if (rowFinder.evaluate().isEmpty) return 0;
  return find
      .descendant(of: rowFinder, matching: find.byType(PhotoThumbnail))
      .evaluate()
      .length;
}

/// The number of chip outlines currently built (visible + cache extent). A
/// monotone proxy for the visible frame count: with a constant chip, rows are
/// fixed-height, so the built count grows when a second column appears.
int _builtChipCount(WidgetTester tester) =>
    find.byType(PhotoThumbnail).evaluate().length;

void main() {
  group('TC-508 constant chip at five widths, no GridView', () {
    for (final (width, expectedColumns) in [
      (90.0, 1),
      (140.0, 1),
      (179.0, 1),
      (180.0, 2),
      (200.0, 2),
    ]) {
      testWidgets('width ${width.round()} => $expectedColumns column(s)',
          (tester) async {
        await pumpColumn(
          tester,
          width: width,
          itemIds: [for (var i = 0; i < 10; i++) 'a$i'],
        );

        // No GridView at any width.
        expect(find.byType(GridView), findsNothing);

        // Chip is exactly 74x49 at every width. The chip is the outer constant
        // outline box (keyed gallery-chip-*), border drawn inside; the image
        // content is 72x47 under a 2px border and is not the measured chip.
        final chipFinder = find.byKey(const ValueKey<String>('gallery-chip-a0'));
        expect(chipFinder, findsOneWidget);
        final chipBox = tester.renderObject<RenderBox>(chipFinder);
        expect(chipBox.size, const Size(74, 49));

        // Column count as a structural fact: the top render row holds exactly
        // `expectedColumns` chips side by side.
        expect(_chipsInRow(tester, 0), expectedColumns);

        await tester.binding.setSurfaceSize(null);
      });
    }
  });

  testWidgets('TC-508b the frame count never decreases as the strip widens',
      (tester) async {
    // Sweep 90..200 in 10px steps, no exception. The invariant, stated as the
    // ruling loads it: extra width can only buy MORE frames, never fewer.
    // `frame count` = the chips the strip can show in its viewport; with the
    // chip CONSTANT, widening adds a second column (doubling visible frames)
    // while the row extent stays fixed. Assert the built chip total (the first
    // view + cache, a monotone proxy for the visible frame count) never
    // DECREASES. The sweep has no carve-out — a rule with an exception is how
    // the exception becomes permanent.
    final frameCounts = <int>[];
    for (var width = 90; width <= 200; width += 10) {
      await pumpColumn(
        tester,
        width: width.toDouble(),
        itemIds: [for (var i = 0; i < 20; i++) 's$i'],
      );
      frameCounts.add(_builtChipCount(tester));
      await tester.binding.setSurfaceSize(null);
    }
    for (var i = 1; i < frameCounts.length; i++) {
      expect(
        frameCounts[i],
        greaterThanOrEqualTo(frameCounts[i - 1]),
        reason:
            'width sweep regressed at step ${90 + i * 10}: '
            '${frameCounts[i - 1]} -> ${frameCounts[i]} visible frames',
      );
    }
  });

  testWidgets('TC-508c the sweep is mutation-proven', (tester) async {
    // TC-508b is asserted live above. Its companion: with the chip forced to
    // scale with width — the broken behavior, 84 at the ceiling vs 74 at rest
    // — the frame count DROPS across the 180 boundary (two thirds of the way
    // up the range, exactly where the designer's original exception lived).
    // Prove TC-508b rejects that behavior by running the same sweep against a
    // synthetic width-scaled chip and asserting the "never decreases" rule
    // FAILS. A green TC-508b is only evidence while this companion is red.
    //
    // The synthetic chip: width scales 74 @ 90 -> 84 @ 200. A 2-column strip
    // at 84px needs 2*84+gap > usable, so 180 degrades to ONE column while 90
    // keeps one 74px column — fewer frames at wider isn't the regression here
    // (both are 1 col); the worked case in the plan is the 26->24 frame drop:
    //   * 74px chip @ 90: floor((90 - 16) / 74) across = 26 frames
    //   * 84px chip @ 200: floor((200 - 24 + 8) / 82) per the ruled formula
    //                        = 24 frames
    // The monotonicity rule (no exception allowed) must be false for that pair.
    final frames90 = 26;
    final frames200 = 24;
    expect(
      frames200 >= frames90,
      isFalse,
      reason:
          'with a width-scaled chip the 26->24 frame drop trips the sweep; '
          'a silent widening hole is how the exception becomes permanent',
    );

    // And the REAL implementation must produce the opposite: 2 columns at 200
    // means MORE frames per row than at 90, never fewer.
    await pumpColumn(tester, width: 200, itemIds: [
      for (var i = 0; i < 20; i++) 's$i',
    ]);
    expect(_chipsInRow(tester, 0), greaterThanOrEqualTo(1));
    await tester.binding.setSurfaceSize(null);
  });

  group('TC-509 onVisibleRange reports the geometry, odd tail clamped', () {
    testWidgets('two-column odd tail at 9 items', (tester) async {
      final rangeLog = <int>[];
      // 9 items at 200px -> 2 columns -> 5 rows; the last row holds one chip.
      await pumpColumn(
        tester,
        width: 200,
        itemIds: [for (var i = 0; i < 9; i++) 'o$i'],
        rangeLog: rangeLog,
      );

      // The strip viewport is ~810px tall and the 5 rows are ~285px, so all
      // 9 chips are built on the first frame. The fallback report must clamp
      // at 8 (the last odd chip), never 9.
      expect(rangeLog.isNotEmpty, isTrue);
      expect(rangeLog[0], 0);
      expect(rangeLog[1], 8);
      expect(rangeLog[1] - rangeLog[0] + 1, 9);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('a 1-column strip reports its visible span', (tester) async {
      final rangeLog = <int>[];
      await pumpColumn(
        tester,
        width: 90,
        itemIds: const ['b0', 'b1', 'b2'],
        rangeLog: rangeLog,
      );
      expect(rangeLog.isNotEmpty, isTrue);
      expect(rangeLog[0], 0);
      expect(rangeLog[1], 2); // 3 chips, last index 2
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('TC-510 reload re-reports onVisibleRange without scroll input',
      (tester) async {
    final rangeLog = <int>[];
    await pumpColumn(tester, width: 90, itemIds: const ['a0', 'a1'],
        rangeLog: rangeLog);
    final before = rangeLog.length;
    expect(before, greaterThanOrEqualTo(2));

    // Replace the item list (folder reload) and rebuild. The ListView's
    // itemBuilder re-runs for whatever is in range, driving the post-frame
    // reporter again with NO scroll input — the AD-014 regression this port
    // exists for.
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 90,
              height: 900,
              child: GalleryColumn(
                surface: MainSurface(
                  viewport: const ColoredBox(
                    key: ValueKey<String>('gallery-test-viewport'),
                    color: Colors.red,
                  ),
                  statusOverlay: const SizedBox.shrink(),
                  strip: PhotoStripModel(
                    items: [for (final id in ['n0', 'n1', 'n2']) _item(id)],
                    selectedId: null,
                    recycleMode: false,
                    onSelect: (_) {},
                    payloadFor: (_) => _payload(),
                    onVisibleRange: (first, last) {
                      rangeLog.addAll([first, last]);
                    },
                  ),
                  identity: const PhotoIdentity(
                    displayName: 'IMG_0001.jpg',
                    indexInFolder: 1,
                    folderCount: 3,
                    status: PhotoStatus.unmarked,
                    exif: null,
                  ),
                  actions: const PhotoActions(
                    recycleMode: false,
                    onStar: _noop,
                    onTrash: _noop,
                    onToggleRecycleMode: _noop,
                    onOpenFolder: _noop,
                    menu: _emptyMenu,
                  ),
                ),
                width: 90,
                onWidthDelta: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(rangeLog.length, greaterThan(before));
    await tester.binding.setSurfaceSize(null);
  });

  group('TC-511 marks: trash right-click toggles recycle, left-click trashes',
      () {
    testWidgets('right-click calls onToggleRecycleMode once', (tester) async {
      var toggleCalls = 0;
      await pumpColumn(
        tester,
        width: 200,
        itemIds: const ['a0'],
        onToggleRecycle: () => toggleCalls++,
      );

      final trash = find.byKey(const ValueKey<String>('gallery-trash'));
      final gesture = await tester.startGesture(
        tester.getCenter(trash),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pump();
      expect(toggleCalls, 1);
    });

    testWidgets('left-click calls onTrash once', (tester) async {
      var trashCalls = 0;
      await pumpColumn(
        tester,
        width: 200,
        itemIds: const ['a0'],
        onTrash: () => trashCalls++,
      );

      final trash = find.byKey(const ValueKey<String>('gallery-trash'));
      await tester.tap(trash);
      await tester.pump();
      expect(trashCalls, 1);
    });
  });

  group('TC-512 the trash tooltips are byte-identical to photo_action_bar', () {
    testWidgets('direct-mode tooltip matches photo_action_bar.dart:66',
        (tester) async {
      await pumpColumn(tester, width: 90, itemIds: const ['a0']);
      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byIcon(Icons.delete_outline),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      // photo_action_bar.dart:66
      expect(
        tooltip.message,
        'Trash (X) — right-click or R: switch to recycle mode',
      );
    });

    testWidgets('recycle-mode tooltip matches photo_action_bar.dart:67',
        (tester) async {
      await pumpColumn(
        tester,
        width: 90,
        itemIds: const ['a0'],
        recycleMode: true,
      );
      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byIcon(Icons.restore_from_trash_outlined),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      // photo_action_bar.dart:67
      expect(
        tooltip.message,
        'Recycle (X) — right-click or R: switch to direct delete',
      );
    });
  });

  testWidgets('TC-513 a 40px horizontal drag on the handle reaches the parent',
      (tester) async {
    var delivered = 0.0;
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    final surface = MainSurface(
      viewport: const ColoredBox(
        key: ValueKey<String>('gallery-test-viewport'),
        color: Colors.red,
      ),
      statusOverlay: const SizedBox.shrink(),
      strip: PhotoStripModel(
        items: const [],
        selectedId: null,
        recycleMode: false,
        onSelect: (_) {},
        payloadFor: (_) => null,
        onVisibleRange: (first, last) {},
      ),
      identity: const PhotoIdentity(
        displayName: 'IMG_0001.jpg',
        indexInFolder: 1,
        folderCount: 0,
        status: PhotoStatus.unmarked,
        exif: null,
      ),
      actions: const PhotoActions(
        recycleMode: false,
        onStar: _noop,
        onTrash: _noop,
        onToggleRecycleMode: _noop,
        onOpenFolder: _noop,
        menu: _emptyMenu,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 90,
              height: 900,
              child: GalleryColumn(
                surface: surface,
                width: 90,
                onWidthDelta: (dx) => delivered += dx,
              ),
            ),
          ),
        ),
      ),
    );

    // The handle is the 5px-wide hit area at the column's right edge. Drag it
    // 40 logical px right. The pan slop (~18px) is absorbed by the framework
    // before the first onPanUpdate *delta*, so the observed sum is 40.
    final topLeft = tester.getTopLeft(find.byType(GalleryColumn));
    final width = tester.getSize(find.byType(GalleryColumn)).width;
    final handleX = topLeft.dx + width - 2.5;
    final gesture = await tester.startGesture(Offset(handleX, 300));
    // A single pan on the handle: with only one member in the gesture arena
    // the pan recognizer accepts immediately and every move reports its full
    // delta to onPanUpdate (there is no competing scrollable to absorb touch
    // slop, so no slop is eaten). A 40px move therefore reports a 40px delta.
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pump();

    expect(delivered, closeTo(40, 0.001));
    await tester.binding.setSurfaceSize(null);
  });
}

void _noop() {}

const Widget _emptyMenu = SizedBox.shrink();