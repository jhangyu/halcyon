// TC-600..TC-608: gallery mobile surface per
// docs/logs/2026-09-01/mockup/gallery/c3-mobile-{light,dark}.html frames
// 1/2/4 and NOTES.md. Goes through the real seam
// (`LayoutTheme.buildMobileSurface`), pumped at the mockup's own phone-sized
// `tester.view.physicalSize` (reset in teardown, no platform faking, per
// task #15 instructions).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/models/rename_rule.dart' show ExifMetadata;
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/layout/common/exif_caption.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_layout.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_mobile.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

const ValueKey<String> _kViewportKey = ValueKey<String>(
  'gallery.mobile.test.viewport',
);

MainSurface _surfaceWith({
  PhotoIdentity? identity,
  List<PhotoItem> items = const [],
  String? selectedId,
  void Function(String id)? onSelect,
}) => MainSurface(
  viewport: const ColoredBox(key: _kViewportKey, color: Colors.blue),
  statusOverlay: const SizedBox.shrink(),
  strip: PhotoStripModel(
    items: items,
    selectedId: selectedId,
    recycleMode: false,
    onSelect: onSelect ?? (_) {},
    payloadFor: (_) => null,
    onVisibleRange: (_, __) {},
  ),
  identity: identity,
  actions: PhotoActions(
    recycleMode: false,
    onStar: () {},
    onTrash: () {},
    onToggleRecycleMode: () {},
    onOpenFolder: () {},
    menu: const SizedBox.shrink(),
  ),
);

/// Pumps the real `GalleryLayout.buildMobileSurface` seam at the mockup's own
/// 390x844 phone viewport (`c3-mobile-light.html:83` `.phone{width:390px;
/// height:844px}`). Wrapped in a real `AppState` `ChangeNotifierProvider`
/// because the welcome state's Open Folder button reads it, same as the
/// desktop welcome (`_GalleryEmptyState`) does.
Future<void> _pumpMobile(
  WidgetTester tester,
  MainSurface surface, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  const theme = GalleryLayout();
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        theme: theme.themeDataFor(brightness),
        home: Scaffold(
          body: Builder(
            builder: (context) => theme.buildMobileSurface(context, surface),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('TC-600 mobile surface fills the phone viewport, both brightnesses', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('$brightness: fills 390x844', (tester) async {
        final surface = _surfaceWith(
          identity: const PhotoIdentity(
            displayName: 'DSC_4471.NEF',
            indexInFolder: 24,
            folderCount: 318,
            status: PhotoStatus.unmarked,
            exif: ExifMetadata(camera: 'Nikon Z 8', iso: 200),
          ),
        );
        await _pumpMobile(tester, surface, brightness: brightness);
        expect(find.byType(GalleryMobileSurface), findsOneWidget);
        final size = tester.getSize(find.byType(GalleryMobileSurface));
        expect(size.width, 390);
        expect(size.height, 844);
      });
    }
  });

  testWidgets('TC-601 the photo fills the frame, no permanent chrome at rest',
      (tester) async {
    final surface = _surfaceWith(
      identity: const PhotoIdentity(
        displayName: 'DSC_4471.NEF',
        indexInFolder: 24,
        folderCount: 318,
        status: PhotoStatus.unmarked,
        exif: null,
      ),
    );
    await _pumpMobile(tester, surface);
    expect(find.byKey(_kViewportKey), findsOneWidget);
    // At rest (frame 1) the filmstrip is not summoned.
    expect(find.byKey(kGalleryMobileStripKey), findsNothing);
  });

  testWidgets('TC-602 centre tap summons the filmstrip (R3); tap again hides it',
      (tester) async {
    final items = [
      PhotoItem(id: 'a', files: [File('a.jpg')]),
      PhotoItem(id: 'b', files: [File('b.jpg')]),
    ];
    final surface = _surfaceWith(
      identity: const PhotoIdentity(
        displayName: 'DSC_4471.NEF',
        indexInFolder: 1,
        folderCount: 2,
        status: PhotoStatus.unmarked,
        exif: null,
      ),
      items: items,
      selectedId: 'a',
    );
    await _pumpMobile(tester, surface);
    expect(find.byKey(kGalleryMobileStripKey), findsNothing);

    await tester.tap(find.byKey(kGalleryMobileTapZoneKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kGalleryMobileStripKey), findsOneWidget);

    await tester.tap(find.byKey(kGalleryMobileTapZoneKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kGalleryMobileStripKey), findsNothing);
  });

  testWidgets('TC-603 filmstrip chip tap selects the photo (chrome on)',
      (tester) async {
    String? tapped;
    final items = [
      PhotoItem(id: 'a', files: [File('a.jpg')]),
      PhotoItem(id: 'b', files: [File('b.jpg')]),
    ];
    final surface = _surfaceWith(
      identity: const PhotoIdentity(
        displayName: 'a.jpg',
        indexInFolder: 1,
        folderCount: 2,
        status: PhotoStatus.unmarked,
        exif: null,
      ),
      items: items,
      selectedId: 'a',
      onSelect: (id) => tapped = id,
    );
    await _pumpMobile(tester, surface);
    await tester.tap(find.byKey(kGalleryMobileTapZoneKey));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('gallery-mobile-chip-tap-b')));
    await tester.pumpAndSettle();
    expect(tapped, 'b');
  });

  testWidgets(
    'TC-604 selected chip is drawn larger with the accent outline (mockup .fr.here)',
    (tester) async {
      final items = [
        PhotoItem(id: 'a', files: [File('a.jpg')]),
        PhotoItem(id: 'b', files: [File('b.jpg')]),
      ];
      final surface = _surfaceWith(
        identity: const PhotoIdentity(
          displayName: 'a.jpg',
          indexInFolder: 1,
          folderCount: 2,
          status: PhotoStatus.unmarked,
          exif: null,
        ),
        items: items,
        selectedId: 'b',
      );
      await _pumpMobile(tester, surface);
      await tester.tap(find.byKey(kGalleryMobileTapZoneKey));
      await tester.pumpAndSettle();

      final selectedRect = tester.getSize(
        find.byKey(const ValueKey<String>('gallery-mobile-chip-b')),
      );
      final restRect = tester.getSize(
        find.byKey(const ValueKey<String>('gallery-mobile-chip-a')),
      );
      expect(selectedRect.width, kGalleryMobileChipWidthSelected);
      expect(selectedRect.height, kGalleryMobileChipHeightSelected);
      expect(restRect.width, kGalleryMobileChipWidth);
      expect(restRect.height, kGalleryMobileChipHeight);
    },
  );

  testWidgets('TC-605 wall label carries filename, index and EXIF (compact)',
      (tester) async {
    final surface = _surfaceWith(
      identity: const PhotoIdentity(
        displayName: 'DSC_4471.NEF',
        indexInFolder: 24,
        folderCount: 318,
        status: PhotoStatus.unmarked,
        exif: ExifMetadata(camera: 'Nikon Z 8', iso: 200),
      ),
    );
    await _pumpMobile(tester, surface);
    expect(find.text('DSC_4471.NEF'), findsOneWidget);
    expect(find.text('24 of 318'), findsOneWidget);
    final caption = tester.widget<ExifCaption>(find.byType(ExifCaption));
    expect(caption.compact, isTrue);
  });

  testWidgets('TC-606 no identity: gallery mobile welcome renders (mockup frame 4)',
      (tester) async {
    await _pumpMobile(tester, _surfaceWith(identity: null));
    expect(find.byKey(const Key('galleryMobileEmptyMount')), findsOneWidget);
    expect(find.byKey(const Key('galleryMobileEmptyOpenFolder')), findsOneWidget);
    expect(find.text('No folder open'), findsOneWidget);
    // The welcome frame draws no permanent chrome: no wall label, no strip.
    expect(find.byKey(kGalleryMobileLabelKey), findsNothing);
    expect(find.byKey(kGalleryMobileStripKey), findsNothing);
  });

  testWidgets(
    'TC-607 welcome mount is 300x200 (mobile scale, distinct from desktop '
    '432x288)',
    (tester) async {
      await _pumpMobile(tester, _surfaceWith(identity: null));
      final size = tester.getSize(
        find.byKey(const Key('galleryMobileEmptyMount')),
      );
      expect(size.width, 300);
      expect(size.height, 200);
    },
  );

  testWidgets('TC-608 star/trash marks in the wall label invoke actions',
      (tester) async {
    var starred = false;
    var trashed = false;
    final surface = MainSurface(
      viewport: const ColoredBox(key: _kViewportKey, color: Colors.blue),
      statusOverlay: const SizedBox.shrink(),
      strip: PhotoStripModel(
        items: const [],
        selectedId: null,
        recycleMode: false,
        onSelect: (_) {},
        payloadFor: (_) => null,
        onVisibleRange: (_, __) {},
      ),
      identity: const PhotoIdentity(
        displayName: 'DSC_4471.NEF',
        indexInFolder: 24,
        folderCount: 318,
        status: PhotoStatus.unmarked,
        exif: null,
      ),
      actions: PhotoActions(
        recycleMode: false,
        onStar: () => starred = true,
        onTrash: () => trashed = true,
        onToggleRecycleMode: () {},
        onOpenFolder: () {},
        menu: const SizedBox.shrink(),
      ),
    );
    await _pumpMobile(tester, surface);
    await tester.tap(find.byKey(const ValueKey<String>('gallery-mobile-star')));
    await tester.tap(find.byKey(const ValueKey<String>('gallery-mobile-trash')));
    expect(starred, isTrue);
    expect(trashed, isTrue);
  });
}
