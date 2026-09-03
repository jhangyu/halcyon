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
      revision: ValueNotifier<int>(0),
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

void main() {
  // TC-508/508b/508c RETIRED 2026-09-02 by user ruling, replaced by
  // TC-543..545 below. They asserted the superseded contract: a CONSTANT
  // 74x49 chip, a second column from 180px, and the invariant "widening the
  // strip never shows FEWER frames". The new rule is the opposite — the chip
  // scales with the gutter and the strip is always one column — so widening
  // now shows fewer, larger frames BY DESIGN. Keeping the old assertions
  // would have meant either a red suite or, worse for 508b (whose built-chip
  // proxy still happened to pass), a green test standing guard over an
  // invariant the product deliberately no longer holds.
  // The one part of TC-508 that survived the ruling is structural and is kept
  // inside TC-543: the strip is a ListView, never a GridView.
  group('TC-543 the chip scales with the gutter, one centred column', () {
    for (final width in [90.0, 120.0, 160.0, 200.0]) {
      testWidgets('chip tracks the gutter at width ${width.round()}',
          (tester) async {
        await pumpColumn(
          tester,
          width: width,
          itemIds: [for (var i = 0; i < 10; i++) 'a$i'],
        );

        // Structural survivor of the old TC-508: never a grid.
        expect(find.byType(GridView), findsNothing);

        final chipFinder = find.byKey(const ValueKey<String>('gallery-chip-a0'));
        final chipBox = tester.renderObject<RenderBox>(chipFinder);

        // The chip fills the strip's content width: gutter minus its
        // CONSTANT 8px padding (the old 8->12 step made the first pixel of a
        // drag shrink the chip — see TC-544), and keeps 3:2.
        expect(chipBox.size.width, closeTo(width - 2 * 8.0, 0.5));
        expect(chipBox.size.height, closeTo(chipBox.size.width / (3 / 2), 0.5));

        // Exactly one column at EVERY width, including the two that used to
        // produce a second one.
        expect(_chipsInRow(tester, 0), 1);

        await tester.binding.setSurfaceSize(null);
      });
    }
  });

  testWidgets('TC-544 the chip grows monotonically, sampled every pixel',
      (tester) async {
    // Replacement invariant for the retired TC-508b: dragging wider must never
    // make the picture SMALLER.
    //
    // STRIDE 1, and that is the whole point. The first version of this test
    // stepped by 10 and was GREEN over a real defect: the filmstrip padding
    // stepped 8 -> 12 the moment the gutter passed 90, so the chip dropped
    // 74 -> 67 at w=91 and did not recover until 98 — a dip that every
    // multiple of 10 steps straight over. A sweep whose stride is coarser
    // than the discontinuity it hunts is not a sweep, it is a coincidence.
    // No carve-out anywhere in the range, for the same reason as before: a
    // rule with an exception is how the exception becomes permanent.
    double? previous;
    for (var width = 90; width <= 200; width += 1) {
      await pumpColumn(
        tester,
        width: width.toDouble(),
        itemIds: const ['only'],
      );
      final size = tester
          .renderObject<RenderBox>(
            find.byKey(const ValueKey<String>('gallery-chip-only')),
          )
          .size;
      if (previous != null) {
        expect(
          size.width,
          greaterThanOrEqualTo(previous),
          reason: 'chip shrank between ${width - 1}px and ${width}px '
              '($previous -> ${size.width})',
        );
      }
      previous = size.width;
      await tester.binding.setSurfaceSize(null);
    }
    // And it really did GROW over the range, not merely "never shrink" by
    // staying constant — which is exactly what the old contract did.
    expect(previous, greaterThan(74));
  });

  testWidgets('TC-545 a chip narrower than the strip is centred, not left-aligned',
      (tester) async {
    // NON-VACUITY, learned from mutation: while the chip fills the strip's
    // full content width, "centred" and "left-aligned" are the same pixels,
    // so asserting centring on a full-width chip proves nothing (flipping the
    // row to MainAxisAlignment.start left the test green). This case forces a
    // deliberately NARROW chip through the production test hook, which is the
    // only configuration where the alignment is observable at all.
    addTearDown(() => GalleryColumn.debugChipWidthForWidth = null);
    GalleryColumn.debugChipWidthForWidth = (_) => 40.0;

    await pumpColumn(tester, width: 160, itemIds: const ['mid']);

    final strip = tester.getRect(find.byType(ListView));
    final chip = tester.getRect(
      find.byKey(const ValueKey<String>('gallery-chip-mid')),
    );

    expect(chip.width, closeTo(40, 0.5)); // the hook really took effect
    expect(chip.left - strip.left, closeTo(strip.right - chip.right, 0.5));
    expect(chip.left - strip.left, greaterThan(1)); // and it is not flush left
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('TC-546 the strip is one column even if the geometry allows more',
      (tester) async {
    // Companion to TC-543's column count, and the reason it is not enough on
    // its own: with a full-width chip the OLD column formula also evaluates to
    // 1, so restoring that formula is invisible. Forcing a narrow chip makes
    // the old formula demand several columns; the strip must still lay out
    // exactly one per row.
    addTearDown(() => GalleryColumn.debugChipWidthForWidth = null);
    GalleryColumn.debugChipWidthForWidth = (_) => 40.0;

    await pumpColumn(
      tester,
      width: 200,
      itemIds: [for (var i = 0; i < 6; i++) 'n$i'],
    );

    expect(_chipsInRow(tester, 0), 1);
    await tester.binding.setSurfaceSize(null);
  });

  group('TC-509 onVisibleRange reports the geometry, odd tail clamped', () {
    testWidgets('tall single-column rows report a clamped visible prefix',
        (tester) async {
      // Was "two-column odd tail at 9 items". Under the 2026-09-02 ruling
      // there is no second column at any width, and a 200px gutter makes each
      // row ~117px tall, so the 9 rows no longer all fit the ~810px viewport.
      // What must still hold is the property the odd-tail case was really
      // guarding: the reported range starts at 0 and never runs past the last
      // item index.
      final rangeLog = <int>[];
      await pumpColumn(
        tester,
        width: 200,
        itemIds: [for (var i = 0; i < 9; i++) 'o$i'],
        rangeLog: rangeLog,
      );

      expect(rangeLog.isNotEmpty, isTrue);
      expect(rangeLog[0], 0);
      expect(rangeLog[1], lessThanOrEqualTo(8));
      expect(rangeLog[1], greaterThanOrEqualTo(0));
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
                    revision: ValueNotifier<int>(0),
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
        revision: ValueNotifier<int>(0),
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

  testWidgets(
    'TC-536 the identity plate carries the counter only, never the filename',
    (tester) async {
      // Revision 2026-09-02: the filename left this 74px-wide well (it
      // truncated on almost every real name) for the wall label at the
      // photo's bottom-right. Nothing in the sidebar may render it.
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      await pumpColumn(
        tester,
        width: 90,
        itemIds: const ['a', 'b', 'c'],
        selectedId: 'a',
      );

      expect(find.text('IMG_0001.jpg'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(GalleryColumn),
          matching: find.textContaining('.jpg'),
        ),
        findsNothing,
      );

      expect(find.text('1 / 3'), findsOneWidget);
      final counter = tester.widget<Text>(find.text('1 / 3'));
      // Alone in the plate, the counter comes up to 10px / mid ink.
      expect(counter.style?.fontSize, 10);
      expect(counter.style?.letterSpacing, 0.12 * 10);
      await tester.binding.setSurfaceSize(null);
    },
  );
}

void _noop() {}

const Widget _emptyMenu = SizedBox.shrink();