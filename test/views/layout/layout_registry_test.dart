import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_desktop.dart';
import 'package:halcyon_flutter/views/layout/layout_registry.dart';
import 'package:halcyon_flutter/views/layout/layout_theme.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

MainSurface _emptySurface() => MainSurface(
  viewport: const SizedBox.shrink(),
  statusOverlay: const SizedBox.shrink(),
  strip: PhotoStripModel(
    items: const [],
    selectedId: null,
    recycleMode: false,
    onSelect: (_) {},
    payloadFor: (_) => null,
    onVisibleRange: (_, __) {},
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
  testWidgets('TC-527: layoutThemeFor is total over LayoutThemeId', (
    tester,
  ) async {
    for (final id in LayoutThemeId.values) {
      expect(layoutThemeFor(id).id, id);
    }
  });

  testWidgets(
    'TC-528: buildMainSurface returns GalleryDesktopSurface with no width branch',
    (tester) async {
      final theme = layoutThemeFor(LayoutThemeId.gallery);

      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => theme.buildMainSurface(
              context,
              _emptySurface(),
            ),
          ),
        ),
      );
      expect(find.byType(GalleryDesktopSurface), findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => theme.buildMainSurface(
              context,
              _emptySurface(),
            ),
          ),
        ),
      );
      expect(find.byType(GalleryDesktopSurface), findsOneWidget);

      addTearDown(() => tester.binding.setSurfaceSize(null));
    },
  );
}
