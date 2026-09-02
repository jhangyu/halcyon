import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_palette.dart';
import 'package:halcyon_flutter/views/theme_tokens.dart';

void main() {
  group('TC-497 galleryThemeData scaffold background follows the mockup', () {
    test('TC-497 light scaffoldBackgroundColor is the mockup --canvas #FAF9F7',
        () {
      expect(
        galleryThemeData(Brightness.light).scaffoldBackgroundColor,
        const Color(0xFFFAF9F7),
      );
    });

    test('TC-497 dark scaffoldBackgroundColor is the mockup --canvas #141414',
        () {
      expect(
        galleryThemeData(Brightness.dark).scaffoldBackgroundColor,
        const Color(0xFF141414),
      );
    });
  });

  group('TC-498 galleryThemeData registers gallery and legacy tokens', () {
    test('light registers a GalleryPalette and keeps HalcyonTokens unchanged',
        () {
      final theme = galleryThemeData(Brightness.light);
      final palette = theme.extension<GalleryPalette>();
      expect(palette, isNotNull);
      expect(palette, same(GalleryPalette.light));
      // R1 evidence: the legacy tokens the Settings/Rename dialogs read are
      // registered exactly as they are today, untouched.
      expect(theme.extension<HalcyonTokens>(), same(HalcyonTokens.light));
    });

    test('dark registers a GalleryPalette and keeps HalcyonTokens unchanged',
        () {
      final theme = galleryThemeData(Brightness.dark);
      final palette = theme.extension<GalleryPalette>();
      expect(palette, isNotNull);
      expect(palette, same(GalleryPalette.dark));
      expect(theme.extension<HalcyonTokens>(), same(HalcyonTokens.dark));
    });
  });

  group('TC-498 continuation: mockup palette spans every slot', () {
    test('light palette values match the mockup --canvas gallery block', () {
      final theme = galleryThemeData(Brightness.light);
      final scheme = theme.colorScheme;
      // --mat mount behind the print
      expect(theme.extension<GalleryPalette>()!.mat, const Color(0xFFF1EFEB));
      // --rail strip & panel surface
      expect(scheme.surface, const Color(0xFFFFFFFF));
      // --sunk inset well / track
      expect(scheme.surfaceContainer, const Color(0xFFF6F5F2));
      // --hair hairline
      expect(scheme.outlineVariant, const Color(0xFFE3DFD8));
      // --hair-strong hairline strong
      expect(scheme.outline, const Color(0xFFD2CDC4));
      // --ink primary text
      expect(scheme.onSurface, const Color(0xFF1C1B19));
      // --ink-dim secondary text
      expect(scheme.onSurfaceVariant, const Color(0xFF6E6A64));
      // --ink-faint tertiary text
      expect(theme.extension<GalleryPalette>()!.textFaint,
          const Color(0xFF9C9791));
      // --accent slate blue
      expect(scheme.primary, const Color(0xFF3F5D72));
      // --star brass
      expect(theme.extension<GalleryPalette>()!.star, const Color(0xFFB08328));
      // --danger oxide
      expect(scheme.error, const Color(0xFFA6432F));
      // .gutter.dragged — 12px 0 34px rgba(28,27,25,.16), shared light/dark.
      expect(theme.extension<GalleryPalette>()!.floatShadow,
          const Color(0x291C1B19));
    });

    test('dark palette values match the mockup canvas gallery block', () {
      final theme = galleryThemeData(Brightness.dark);
      final scheme = theme.colorScheme;
      expect(theme.extension<GalleryPalette>()!.mat, const Color(0xFF1B1B1C));
      expect(scheme.surface, const Color(0xFF1E1E20));
      expect(scheme.surfaceContainer, const Color(0xFF242426));
      expect(scheme.outlineVariant, const Color(0xFF2E2E31));
      expect(scheme.outline, const Color(0xFF3C3C40));
      expect(scheme.onSurface, const Color(0xFFE8E6E2));
      expect(scheme.onSurfaceVariant, const Color(0xFF99958F));
      expect(theme.extension<GalleryPalette>()!.textFaint,
          const Color(0xFF6B6863));
      expect(scheme.primary, const Color(0xFF7FA3BC));
      expect(theme.extension<GalleryPalette>()!.star, const Color(0xFFD7A54A));
      expect(scheme.error, const Color(0xFFC86B58));
      // .gutter.dragged — shared light/dark rule, ink #1C1B19 at 16% alpha.
      expect(theme.extension<GalleryPalette>()!.floatShadow,
          const Color(0x291C1B19));
    });
  });

  group('TC-498 constraint: chrome slots recoloured to the gallery hues', () {
    test('light popup menu and divider use --rail and --hair, no legacy grey',
        () {
      final theme = galleryThemeData(Brightness.light);
      expect(theme.popupMenuTheme.color, const Color(0xFFFFFFFF)); // --rail
      // The action-menu divider follows the legacy baseline for dividers, and
      // the popup divider uses the hairline.
      expect(theme.dividerColor, Colors.transparent);
      expect(theme.dividerTheme.color, const Color(0xFFE3DFD8)); // --hair
    });

    test('dark popup menu and divider use --rail and --hair', () {
      final theme = galleryThemeData(Brightness.dark);
      expect(theme.popupMenuTheme.color, const Color(0xFF1E1E20)); // --rail
      expect(theme.dividerColor, Colors.transparent);
      expect(theme.dividerTheme.color, const Color(0xFF2E2E31)); // --hair
    });
  });

  group('gallery float shadow token (T6 palette centralization)', () {
    test('light and dark floatShadow both match the shared .gutter.dragged rule',
        () {
      // Mockup `c1-desktop-{light,dark}.html:238` — one shared CSS rule:
      // `box-shadow:12px 0 34px rgba(28,27,25,.16)`. 16% alpha is 0x29, and the
      // hue is the page ink #1C1B19, so the faithful value is 0x291C1B19 in
      // both brightnesses (identical — there is no per-brightness shadow).
      expect(GalleryPalette.light.floatShadow, const Color(0x291C1B19));
      expect(GalleryPalette.dark.floatShadow, const Color(0x291C1B19));
    });

    test('copyWith replaces floatShadow and keeps the other fields', () {
      final changed = GalleryPalette.light.copyWith(
        floatShadow: const Color(0xFFFFFFFF),
      );
      expect(changed.floatShadow, const Color(0xFFFFFFFF));
      expect(changed, isNot(same(GalleryPalette.light)));
      // Untouched fields stay identical to the source palette.
      expect(changed.mat, GalleryPalette.light.mat);
      expect(changed.textFaint, GalleryPalette.light.textFaint);
      expect(changed.star, GalleryPalette.light.star);
    });

    test('copyWith with no args returns an equal-value palette', () {
      final copied = GalleryPalette.light.copyWith();
      expect(copied.floatShadow, GalleryPalette.light.floatShadow);
      expect(copied.mat, GalleryPalette.light.mat);
      expect(copied.textFaint, GalleryPalette.light.textFaint);
      expect(copied.star, GalleryPalette.light.star);
    });

    test('lerp interpolates floatShadow with other channels', () {
      final lerped = GalleryPalette.light
          .lerp(GalleryPalette.dark, 0.5)
          .floatShadow;
      expect(GalleryPalette.light.floatShadow, GalleryPalette.dark.floatShadow);
      expect(lerped, GalleryPalette.light.floatShadow);
    });
  });

  group('TC-498 verify M3 and the seam contract', () {
    test('useMaterial3 is carried over', () {
      expect(galleryThemeData(Brightness.light).useMaterial3, isTrue);
      expect(galleryThemeData(Brightness.dark).useMaterial3, isTrue);
    });

    testWidgets('GalleryPalette.of falls back to dark outside the theme',
        (tester) async {
      late GalleryPalette seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              seen = GalleryPalette.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, same(GalleryPalette.dark));
    });
  });
}