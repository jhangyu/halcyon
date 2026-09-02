// TC-542: Cmd+O / Ctrl+O opens a folder.
//
// The welcome screen's hint line and the actions menu's shortcut label both
// advertise this chord. It is now a real, chord-aware ShortcutAction
// (ShortcutBindings.actionForChord) dispatched by main_screen.dart's handler
// — see lib/models/shortcut_bindings.dart and lib/views/main_screen.dart.
// gallery_desktop.dart no longer owns any shortcut wiring of its own, so
// every case here pumps the REAL assembled app: the surface's own Focus used
// to sit below main_screen's autofocused Focus, and only a real pump can show
// whether key events actually reach the handler that owns them (the finding
// this file's original version was created to guard against — see
// docs/logs/2026-09-02/gallery-remediation-handover.md §7).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:halcyon_flutter/main.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/temp_dirs.dart';

/// Pumps the real [HalcyonApp] over a fresh [AppState] pointed at a temp
/// folder with one photo, and wires a mock file_selector channel so the
/// picker's invocation (not its native UI) is the observable "did the chord
/// fire" signal. Returns the invocation counter.
Future<int Function()> _pumpRealApp(WidgetTester tester) async {
  late AppState state;
  await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('halcyon_cmdo_');
    addTempDirTeardown(dir);
    await File('${dir.path}/IMG_0001.jpg').writeAsBytes(const [1, 2, 3]);
    state = AppState(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageFailure('not-used', 'no-op'),
    );
    addTearDown(state.dispose);
    await state.loadFolder(dir);
  });

  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(value: state, child: const HalcyonApp()),
  );
  // Drain the initial preload's fire-and-forget async work
  // (AppState._preloadImages / ImagePreloadController) before the test
  // proceeds. `loadFolder` does not await it, so without this a pending real
  // Future fires notifyListeners() after this test's `state.dispose()`
  // teardown runs — observed as "used after being disposed" crashing a LATER
  // test in the suite (real Futures outlive the pumping test's fake-async
  // zone; only `runAsync` shares their real event loop).
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump();

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

  return () => pickerCalls;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final (name, modifier) in <(String, LogicalKeyboardKey)>[
    ('meta (macOS ⌘O)', LogicalKeyboardKey.meta),
    ('control (Windows/Linux Ctrl+O)', LogicalKeyboardKey.control),
  ]) {
    testWidgets('TC-542 $name invokes Open Folder in the real app', (tester) async {
      final pickerCalls = await _pumpRealApp(tester);

      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();

      expect(pickerCalls(), 1);
    });
  }

  testWidgets('TC-542 the bare O key does NOT open a folder', (tester) async {
    // The chord must be the chord: an unmodified O is a plain key the rest of
    // the app is free to bind, and swallowing it here would be a regression
    // no other assertion in this file would catch.
    final pickerCalls = await _pumpRealApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();

    expect(pickerCalls(), 0);
  });

  testWidgets(
    'TC-542 the chord reaches the surface inside the real app, folder loaded',
    (tester) async {
      // Focus reality check, kept from the original finding: main_screen
      // wraps the surface in its own autofocused Focus; if that node
      // swallowed the key, the shortcut would work in isolation and be dead
      // in the product.
      final pickerCalls = await _pumpRealApp(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pump();

      expect(pickerCalls(), 1);
    },
  );
}
