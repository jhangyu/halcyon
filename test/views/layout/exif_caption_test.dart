import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_palette.dart';

/// T14 white-box checks for the R4 EXIF corner caption.
///
/// TC numbering: user ruled a full +7 shift of the gallery block — gallery
/// TC-487..522 maps to TC-494..529, so this task's three identifiers land on
/// TC-514..516 (originally TC-507..509). These IDs are final; the docs registry
/// is out of this task's ownership.
void main() {
  ExifMetadata full() => const ExifMetadata(
        camera: 'Nikon Z 8',
        focalLength: 85,
        aperture: 5.6,
        shutter: '1/500',
        iso: 200,
      );

  Future<void> pumpCaption(WidgetTester tester, ExifCaption caption) async {
    await tester.pumpWidget(
      MaterialApp(
        // The gallery theme supplies the slot colours these fixtures read.
        theme: galleryThemeData(Brightness.light),
        home: Scaffold(
          body: Center(child: caption),
        ),
      ),
    );
    await tester.pump();
  }

  ExifCaption captionFor(ExifMetadata? exif, {bool compact = false}) =>
      ExifCaption(exif: exif, compact: compact);

  testWidgets('TC-514 all five fields render the exact mockup body string',
      (tester) async {
    await pumpCaption(tester, captionFor(full()));

    final text = tester.widget<Text>(find.text('85 mm · ƒ/5.6 · 1/500 · ISO 200'));
    expect(text.data, '85 mm · ƒ/5.6 · 1/500 · ISO 200');

    // Desktop camera is its own line above the rule.
    expect(find.text('Nikon Z 8'), findsOneWidget);
    final cam = tester.widget<Text>(find.text('Nikon Z 8'));
    expect(cam.style?.fontSize, 9.5);
    expect(cam.style?.letterSpacing, 0.14 * 9.5);
    expect(cam.style?.color, GalleryPalette.light.textFaint); // --ink-faint

    // Body style: 10.5px, 0.1em tracking, --ink-dim.
    expect(text.style?.fontSize, 10.5);
    expect(text.style?.letterSpacing, 0.1 * 10.5);
    expect(text.style?.color, Color(0xFF6E6A64)); // light --ink-dim
  });

  testWidgets('TC-514 desktop builds a right-aligned camera / rule / body stack',
      (tester) async {
    await pumpCaption(tester, captionFor(full()));

    final column = tester.widget<Column>(find.byType(Column));
    expect(column.crossAxisAlignment, CrossAxisAlignment.end);
    expect(column.mainAxisSize, MainAxisSize.min);

    // Camera, 34×1 rule, then body — the museum-label order.
    final children = column.children.whereType<Widget>().toList();
    int? iCamera, iRule, iBody;
    for (var i = 0; i < children.length; i++) {
      final w = children[i];
      if (w is Text && w.data == 'Nikon Z 8') iCamera = i;
      if (w is Container && w.constraints == const BoxConstraints.tightFor(width: 34, height: 1)) {
        iRule = i;
      }
      if (w is Text && w.data == '85 mm · ƒ/5.6 · 1/500 · ISO 200') iBody = i;
    }
    expect(iCamera, isNotNull);
    expect(iRule, isNotNull);
    expect(iBody, isNotNull);
    expect(iRule!, greaterThan(iCamera!));
    expect(iBody!, greaterThan(iRule));

    final rule = children[iRule] as Container;
    expect(rule.color, Color(0xFFD2CDC4)); // light --hair-strong / outline
  });

  testWidgets('TC-515 aperture and ISO null join without doubled or trailing separator',
      (tester) async {
    const exif = ExifMetadata(
      focalLength: 85,
      shutter: '1/500',
    );
    await pumpCaption(tester, captionFor(exif));

    // No camera, no rule: just the exactly-matching body line.
    expect(find.byType(Text), findsOneWidget);
    expect(find.text('85 mm · 1/500'), findsOneWidget);
    // No doubled separator artifacts anywhere in the subtree.
    final all = find.byType(Text);
    for (final element in all.evaluate()) {
      final text = (element.widget as Text).data ?? '';
      expect(text.contains(' · · '), isFalse);
      expect(text.startsWith(' · ') || text.endsWith(' · '), isFalse);
    }
    // Nothing left over: no camera line, no rule, no placeholder.
    expect(find.textContaining('Nikon'), findsNothing);
    expect(find.byType(Container), findsNothing);
  });

  testWidgets('TC-515 body-only renders no rule or camera and stays a Column',
      (tester) async {
    const exif = ExifMetadata(focalLength: 85, shutter: '1/500');
    await pumpCaption(tester, captionFor(exif));

    final column = tester.widget<Column>(find.byType(Column));
    // Rule is written only when both camera and body are present; the
    // body-only stack is the single Text.
    final children = column.children.whereType<Container>().toList();
    expect(children, isEmpty);
  });

  testWidgets('TC-515 empty fields render the empty widget exactly once',
      (tester) async {
    await pumpCaption(tester, captionFor(const ExifMetadata()));
    // Non-compact: no Text, no Column — only the single Shrink.
    expect(find.byType(SizedBox), findsOneWidget);
    expect(find.byType(Column), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('TC-516 null exif renders a zero-size widget',
      (tester) async {
    await pumpCaption(tester, captionFor(null));

    expect(find.byType(ExifCaption), findsOneWidget);
    final box = tester.getSize(find.byType(ExifCaption));
    expect(box, Size.zero);
  });

  testWidgets('TC-516 compact is one camera-inline line, no rule',
      (tester) async {
    await pumpCaption(tester, captionFor(full(), compact: true));

    final all = find.byType(Text);
    expect(all, findsOneWidget);
    final text = tester.widget<Text>(all);
    expect(text.data, 'Nikon Z 8 · 85 mm · ƒ/5.6 · 1/500 · ISO 200');
    expect(text.style?.fontSize, 9.5);
    expect(text.style?.letterSpacing, 0.06 * 9.5);
    expect(text.style?.color, Color(0xFF6E6A64));

    expect(find.byType(Column), findsNothing);
    expect(find.byType(Container), findsNothing);
  });

  testWidgets('TC-516 compact null exif is also zero-size', (tester) async {
    await pumpCaption(tester, captionFor(null, compact: true));

    expect(tester.getSize(find.byType(ExifCaption)), Size.zero);
  });
}