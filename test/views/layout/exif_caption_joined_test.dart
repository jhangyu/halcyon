// TC-861: ExifCaptionVariant.joined — the two-line, rule-less caption both the
// darkroom (.caption, mockup c2-desktop-dark.html:210-217) and paper (.overcap,
// mockup paper/c1-desktop-dark.html:246-249) themes draw. The museum variant
// (gallery) is asserted unchanged in exif_caption_test.dart, which this task
// does not edit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_palette.dart';

void main() {
  ExifMetadata full() => const ExifMetadata(
        camera: 'FUJIFILM X-T5',
        focalLength: 23,
        aperture: 4,
        shutter: '1/500 s',
        iso: 320,
      );

  Future<void> pumpCaption(WidgetTester tester, ExifCaption caption) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: galleryThemeData(Brightness.dark),
        home: Scaffold(body: Center(child: caption)),
      ),
    );
    await tester.pump();
  }

  /// The museum-label hairline: a 44x1 Container with the rule's own margin.
  Finder ruleFinder() => find.byWidgetPredicate(
        (w) => w is Container && w.margin == const EdgeInsets.only(top: 4, bottom: 3),
      );

  group('TC-861 joined variant: two lines, no rule, camera inline', () {
    testWidgets('name + full EXIF renders exactly two Texts and no rule',
        (tester) async {
      await pumpCaption(
        tester,
        ExifCaption(
          exif: full(),
          fileName: 'DSCF4417.RAF',
          variant: ExifCaptionVariant.joined,
          alignment: CrossAxisAlignment.start,
        ),
      );
      expect(find.byType(Text), findsNWidgets(2));
      expect(ruleFinder(), findsNothing);
      expect(find.text('DSCF4417.RAF'), findsOneWidget);
      expect(
        find.text('FUJIFILM X-T5 · 23 mm · ƒ/4 · 1/500 s · ISO 320'),
        findsOneWidget,
        reason: 'camera is joined into the single EXIF line, not split out',
      );
    });

    testWidgets('titleStyle and detailStyle merge over the variant defaults',
        (tester) async {
      await pumpCaption(
        tester,
        ExifCaption(
          exif: full(),
          fileName: 'DSCF4417.RAF',
          variant: ExifCaptionVariant.joined,
          alignment: CrossAxisAlignment.start,
          titleStyle: const TextStyle(fontFamily: 'serif', fontSize: 15),
          detailStyle: const TextStyle(letterSpacing: 0.55),
          detailGap: 5,
        ),
      );
      final title = tester.widget<Text>(find.text('DSCF4417.RAF'));
      expect(title.style!.fontFamily, 'serif');
      expect(title.style!.fontSize, 15);
      expect(title.style!.height, 1,
          reason: 'unset fields fall back to the variant default');

      final detail = tester.widget<Text>(
        find.text('FUJIFILM X-T5 · 23 mm · ƒ/4 · 1/500 s · ISO 320'),
      );
      expect(detail.style!.letterSpacing, 0.55);
      expect(detail.style!.fontSize, 11);

      expect(
        find.byWidgetPredicate((w) => w is SizedBox && w.height == 5),
        findsOneWidget,
      );
    });

    testWidgets('a name with no readable EXIF draws the title line only',
        (tester) async {
      await pumpCaption(
        tester,
        const ExifCaption(
          exif: null,
          fileName: 'DSCF4417.RAF',
          variant: ExifCaptionVariant.joined,
          alignment: CrossAxisAlignment.start,
        ),
      );
      expect(find.byType(Text), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is SizedBox && w.height == 4),
        findsNothing,
        reason: 'no gap without a second line',
      );
    });

    testWidgets('EXIF with no name draws the EXIF line only', (tester) async {
      await pumpCaption(
        tester,
        ExifCaption(
          exif: full(),
          variant: ExifCaptionVariant.joined,
          alignment: CrossAxisAlignment.start,
        ),
      );
      expect(find.byType(Text), findsOneWidget);
      expect(
        find.text('FUJIFILM X-T5 · 23 mm · ƒ/4 · 1/500 s · ISO 320'),
        findsOneWidget,
      );
    });

    testWidgets('nothing to show renders a zero-size box', (tester) async {
      await pumpCaption(
        tester,
        const ExifCaption(
          exif: null,
          variant: ExifCaptionVariant.joined,
        ),
      );
      expect(tester.getSize(find.byType(ExifCaption)), Size.zero);
    });

    testWidgets('compact ignores the variant and keeps the mobile one-liner',
        (tester) async {
      await pumpCaption(
        tester,
        ExifCaption(
          exif: full(),
          fileName: 'DSCF4417.RAF',
          compact: true,
          variant: ExifCaptionVariant.joined,
        ),
      );
      expect(find.byType(Text), findsOneWidget);
      final line = tester.widget<Text>(find.byType(Text));
      expect(line.style!.fontSize, 9.5);
    });

    testWidgets('museum is still the default variant', (tester) async {
      await pumpCaption(
        tester,
        ExifCaption(exif: full(), fileName: 'DSCF4417.RAF'),
      );
      expect(ruleFinder(), findsOneWidget);
    });
  });
}
