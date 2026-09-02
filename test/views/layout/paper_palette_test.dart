// TC-560: paperThemeData resolves the mockup's :root palette 1:1.
// Source: docs/logs/2026-09-01/mockup/paper/c1-desktop-{light,dark}.html:39-80
// and NOTES.md "Palette — paper".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';
import 'package:halcyon_flutter/views/theme_tokens.dart';

void main() {
  group('TC-560 paperThemeData scaffold background follows the mockup --app', () {
    test('light scaffoldBackgroundColor is #F6F2EA', () {
      expect(
        paperThemeData(Brightness.light).scaffoldBackgroundColor,
        const Color(0xFFF6F2EA),
      );
    });

    test('dark scaffoldBackgroundColor is #1A1815', () {
      expect(
        paperThemeData(Brightness.dark).scaffoldBackgroundColor,
        const Color(0xFF1A1815),
      );
    });
  });

  group('TC-561 paperThemeData registers PaperPalette and legacy tokens (R1)', () {
    test('light registers PaperPalette.light and keeps HalcyonTokens.light', () {
      final theme = paperThemeData(Brightness.light);
      expect(theme.extension<PaperPalette>(), same(PaperPalette.light));
      expect(theme.extension<HalcyonTokens>(), same(HalcyonTokens.light));
    });

    test('dark registers PaperPalette.dark and keeps HalcyonTokens.dark', () {
      final theme = paperThemeData(Brightness.dark);
      expect(theme.extension<PaperPalette>(), same(PaperPalette.dark));
      expect(theme.extension<HalcyonTokens>(), same(HalcyonTokens.dark));
    });
  });

  group('TC-562 mockup palette spans every slot, both brightnesses', () {
    test('light palette values match the mockup :root block', () {
      final theme = paperThemeData(Brightness.light);
      final scheme = theme.colorScheme;
      expect(scheme.surface, const Color(0xFFFBF8F2)); // --paper
      expect(scheme.surfaceContainer, const Color(0xFFEAE4D8)); // --sunk
      expect(scheme.onSurface, const Color(0xFF23201B)); // --ink
      expect(scheme.onSurfaceVariant, const Color(0xFF6B6157)); // --ink2
      expect(
        theme.extension<PaperPalette>()!.textFaint,
        const Color(0xFF9C9285), // --ink3
      );
      expect(scheme.primary, const Color(0xFFA2673E)); // --accent
      expect(
        theme.extension<PaperPalette>()!.accentInk,
        const Color(0xFFFFF9F2), // --accent-ink
      );
      expect(theme.extension<PaperPalette>()!.star, const Color(0xFFC08A22)); // --star
      expect(scheme.error, const Color(0xFFA6402F)); // --danger
    });

    test('dark palette values match the mockup :root block', () {
      final theme = paperThemeData(Brightness.dark);
      final scheme = theme.colorScheme;
      expect(scheme.surface, const Color(0xFF232019)); // --paper
      expect(scheme.surfaceContainer, const Color(0xFF131110)); // --sunk
      expect(scheme.onSurface, const Color(0xFFEDE6DA)); // --ink
      expect(scheme.onSurfaceVariant, const Color(0xFFA69B8C)); // --ink2
      expect(
        theme.extension<PaperPalette>()!.textFaint,
        const Color(0xFF7A7063), // --ink3
      );
      expect(scheme.primary, const Color(0xFFD08A55)); // --accent
      expect(theme.extension<PaperPalette>()!.star, const Color(0xFFE8B44A)); // --star
      expect(scheme.error, const Color(0xFFE0705C)); // --danger
    });
  });

  group('TC-563 PaperPalette copyWith/lerp plumbing', () {
    test('copyWith replaces one field and keeps the others', () {
      final changed = PaperPalette.light.copyWith(star: const Color(0xFFFFFFFF));
      expect(changed.star, const Color(0xFFFFFFFF));
      expect(changed, isNot(same(PaperPalette.light)));
      expect(changed.textFaint, PaperPalette.light.textFaint);
      expect(changed.accentInk, PaperPalette.light.accentInk);
    });

    test('lerp interpolates star between light and dark', () {
      final lerped = PaperPalette.light.lerp(PaperPalette.dark, 0.5).star;
      expect(
        lerped,
        Color.lerp(PaperPalette.light.star, PaperPalette.dark.star, 0.5),
      );
    });

    test('lerp with a non-PaperPalette returns this unchanged', () {
      final result = PaperPalette.light.lerp(null, 0.5);
      expect(result, same(PaperPalette.light));
    });
  });

  testWidgets('PaperPalette.of falls back to dark outside the theme', (tester) async {
    late PaperPalette seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            seen = PaperPalette.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, same(PaperPalette.dark));
  });
}
