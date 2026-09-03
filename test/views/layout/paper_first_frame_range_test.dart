// The paper filmstrip's FIRST-FRAME visible-range report.
//
// Round 2 / Task 6: five copies of the AD-014 "report what I built, from the
// itemBuilder, deferred to end of frame" pattern collapse into
// `VisibleRangeReporter`, unified on gallery_column.dart's policy — when the
// list has no scroll position yet (the first frame), report the accumulated
// BUILT range instead of reporting nothing.
//
// Paper's two strips used to bail out entirely on `!hasClients`, so on their
// very first frame they reported nothing at all and the sidebar payload
// prefetch for the initially-visible rows never started until something else
// triggered a rebuild. This is the gate for that fix; it was RED before the
// adoption landed.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_desktop.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';

PixelPayload _payload() =>
    PixelPayload(width: 4, height: 4, rgba: Uint8List(4 * 4 * 4));

PhotoItem _item(String id) => PhotoItem(id: id, files: [File('src/$id.jpg')]);

/// Same surface construction as `paper_desktop_test.dart`'s `_emptySurface`,
/// with a populated strip and a recording `onVisibleRange`.
MainSurface _surface(
  List<PhotoItem> items,
  void Function(int first, int last) onVisibleRange,
) => MainSurface(
  viewport: const ColoredBox(key: kViewportKey, color: Colors.red),
  statusOverlay: const SizedBox.shrink(),
  strip: PhotoStripModel(
    items: items,
    selectedId: items.first.id,
    recycleMode: false,
    onSelect: (_) {},
    payloadFor: (_) => _payload(),
    onVisibleRange: onVisibleRange,
    revision: ValueNotifier<int>(0),
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

void main() {
  testWidgets(
    'the paper filmstrip reports a visible range on its first frame '
    '(before the list has a scroll position)',
    (tester) async {
      final reports = <(int, int)>[];
      final items = [for (var i = 0; i < 30; i++) _item('p$i')];

      // Same pump as paper_desktop_test.dart's `_pump`.
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: paperThemeData(Brightness.light),
          home: Scaffold(
            body: PaperDesktopSurface(
              surface: _surface(
                items,
                (first, last) => reports.add((first, last)),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // let the post-frame sweep run

      expect(
        reports,
        isNotEmpty,
        reason: 'the first frame must report the rows it built; reporting '
            'nothing until a scroll position exists is the paper/gallery '
            'divergence this task removes',
      );
      expect(reports.first.$1, 0);
      expect(reports.first.$2, greaterThan(0));
    },
  );
}
