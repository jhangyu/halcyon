// TC-542: ⌘O / Ctrl+O opens a folder.
//
// The welcome screen's hint line and the actions menu's shortcut label both
// advertise this chord. Before this test it was an inert affordance: the
// app's ShortcutBindings dispatches on the logical key alone and has no
// modifier representation, so no such binding could exist. The gallery
// surface therefore registers it directly (see the comment at
// GalleryDesktopSurface's CallbackShortcuts).
//
// Both activators are asserted because macOS uses Cmd and Windows/Linux use
// Ctrl, and the advertised label follows the platform.
//
// The second test pumps the REAL app rather than the surface in isolation:
// the surface's own Focus sits below main_screen's autofocused Focus, and
// only a real pump can show whether key events actually reach it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:halcyon_flutter/main.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_desktop.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

import '../../support/temp_dirs.dart';

MainSurface surfaceWith({required VoidCallback onOpenFolder}) => MainSurface(
      viewport: const ColoredBox(key: kViewportKey, color: Colors.red),
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
        onOpenFolder: onOpenFolder,
        menu: const SizedBox.shrink(),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final (name, modifier) in <(String, LogicalKeyboardKey)>[
    ('meta (macOS ⌘O)', LogicalKeyboardKey.meta),
    ('control (Windows/Linux Ctrl+O)', LogicalKeyboardKey.control),
  ]) {
    testWidgets('TC-542 $name invokes Open Folder', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GalleryDesktopSurface(
              surface: surfaceWith(onOpenFolder: () => opened++),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();

      expect(opened, 1);
    });
  }

  testWidgets('TC-542 the bare O key does NOT open a folder', (tester) async {
    // The chord must be the chord: an unmodified O is a plain key the rest of
    // the app is free to bind, and swallowing it here would be a regression
    // no other assertion in this file would catch.
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GalleryDesktopSurface(
            surface: surfaceWith(onOpenFolder: () => opened++),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();

    expect(opened, 0);
  });

  testWidgets(
    'TC-542 the chord reaches the surface inside the real app, folder loaded',
    (tester) async {
      // Focus reality check. main_screen wraps the surface in its own
      // autofocused Focus; if that node swallowed the key, the shortcut would
      // work in isolation and be dead in the product — the exact failure this
      // finding was about.
      late AppState state;
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('halcyon_cmdo_');
        addTempDirTeardown(dir);
        await File('${dir.path}/IMG_0001.jpg').writeAsBytes(const [1, 2, 3]);
        state = AppState(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageFailure('not-used', 'no-op'),
        );
        addTearDown(state.dispose);
        await state.loadFolder(dir);
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const HalcyonApp(),
        ),
      );
      await tester.pump();

      // The real callback opens a native folder picker, which cannot run in a
      // widget test; the assertion is that the chord is DELIVERED to the
      // gallery surface's binding, observed through the file_selector channel
      // being invoked. A dead shortcut invokes nothing at all.
      var pickerCalls = 0;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        pickerCalls++;
        return null; // user cancelled: no folder change, nothing else runs
      });

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pump();

      expect(pickerCalls, 1);
    },
  );
}
