import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'perf/perf_driver.dart'; // PERF-INSTRUMENTATION
import 'providers/app_state.dart';
import 'services/dng_decode_service.dart';
import 'services/open_with_channel.dart';
import 'views/main_screen.dart';

// Flutter's ImageCache defaults to 100MB, which only fits ~1 full-frame
// decoded 24MP JPEG. Tier-1 (window resolution) + tier-2 (full size)
// precaching needs headroom for several images at once.
//
// 768 MiB = 805,306,368 B. Sized against the CHEAP (preview-bearing) corpus,
// NOT the expensive one: a preview-bearing item decodes its tier-2 entry at
// FULL native size (24MP -> 91.55 MiB here) and holds a SECOND, separate
// tier-1 entry, while a no-preview RAW is already window-sized and shares ONE
// entry across both tiers. The dear entries therefore come from the cheap rung.
// Requirement is 626.22 MiB (5 full-size + their coexisting tier-1 entries + 4
// outer tier-1 + sidebar); 640 MiB would leave only 2.2% headroom and evict the
// very entry the no-re-decode guarantee just promised. Derivation:
// docs/logs/2026-08-23/cache-sizing-estimate.md §A.4/§A.6.
//
// This is NOT interchangeable with kPayloadByteBudget: the two are sized
// against different corpora and neither can sanity-check the other.
const int imageCacheMaxBytes = 768 << 20;

void configureImageCache() {
  PaintingBinding.instance.imageCache.maximumSizeBytes = imageCacheMaxBytes;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureImageCache();
  // Composition root: injects the real RAW decoder. AppState's dngDecoder
  // defaults to null (which degrades to the legacy CIRAWFilter bytes path),
  // so this line is what makes the round-3b raw-decode path reachable at all.
  final appState = AppState(
    dngDecoder: halcyonDngFullDecoder,
  ); // PERF-INSTRUMENTATION
  // Finder "Open With" / shell association: load the file's folder and select
  // that photo. Registered before runApp so a launch-time file isn't missed.
  OpenWithChannel.listen(appState.openPhotoAtPath);
  runApp(
    ChangeNotifierProvider.value(
      value: appState, // PERF-INSTRUMENTATION
      child: const HalcyonApp(),
    ),
  );
  // PERF-INSTRUMENTATION
  if (PerfDriver.active) {
    PerfDriver.run(appState);
  }
}

class HalcyonApp extends StatelessWidget {
  const HalcyonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Halcyon',
      themeMode: ThemeMode.system, // Adapt to macOS system theme
      // Antigravity Day Theme
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color.fromARGB(
          255,
          243,
          243,
          243,
        ), // Main preview background
        dividerColor: Colors.transparent,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF0066CC), // Apple blue
          onPrimary: Colors.white,
          surface: Color.fromARGB(255, 225, 225, 225), // Action area bg
          surfaceContainer: Color.fromARGB(255, 232, 232, 232), // Sidebar bg
          surfaceContainerHighest: Color(0xFFD1D1D6),
          onSurface: Color.fromARGB(
            255,
            118,
            118,
            118,
          ), // Unselected text color
        ),
        listTileTheme: const ListTileThemeData(
          selectedTileColor: Color.fromARGB(255, 220, 220, 220), // Fallback
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Color.fromARGB(255, 248, 248, 248),
          elevation: 8,
        ),
        dividerTheme: const DividerThemeData(
          color: Color.fromARGB(255, 220, 220, 220), // Action menu divider
          space: 1,
          thickness: 1,
        ),
        useMaterial3: true,
      ),
      // Custom Layered Night Theme
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color.fromARGB(
          255,
          45,
          45,
          45,
        ), // Main preview background
        dividerColor:
            Colors.transparent, // Remove dividers generally in dark mode
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF0A84FF), // macOS Dark Apple blue
          onPrimary: Colors.white,
          surface: Color.fromARGB(255, 81, 81, 81), // Action area bg
          surfaceContainer: Color.fromARGB(255, 59, 59, 59), // Sidebar bg
          surfaceContainerHighest: Color(0xFF323232), // Hover item bg
          onSurface: Color(0xFFE0E0E0),
        ),
        listTileTheme: const ListTileThemeData(
          selectedTileColor: Color.fromARGB(
            255,
            70,
            70,
            70,
          ), // Explicit selected background color
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Color.fromARGB(
            255,
            60,
            60,
            60,
          ), // Slight darker contextual menu
          elevation: 8,
        ),
        dividerTheme: const DividerThemeData(
          color: Color.fromARGB(
            255,
            81,
            81,
            81,
          ), // Explicit color for PopupMenuDividers
          space: 1,
          thickness: 1,
        ),
        useMaterial3: true,
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
