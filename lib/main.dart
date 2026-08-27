import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'perf/perf_driver.dart'; // PERF-INSTRUMENTATION
import 'providers/app_state.dart';
import 'services/image_pipeline/cache_budget.dart';
import 'services/image_pipeline/full_decoder_dispatch.dart';
import 'services/platform/open_with_channel.dart';
import 'views/main_screen.dart';
import 'views/theme_tokens.dart';

// Flutter's ImageCache defaults to 100MB, which only fits ~1 full-frame
// decoded 24MP JPEG. Tier-1 (window resolution) + tier-2 (full size)
// precaching needs headroom for several images at once.

void configureImageCache() {
  // M6 F-25/P5.1: derived from physical memory via imageCacheBudgetBytes,
  // behind an injectable seam — dart:io has no platform-neutral
  // total-physical-memory API (ProcessInfo is RSS-only) and Platform.isX
  // branches are forbidden (C-3), so this passes null (no source) and gets
  // back the same fixed ceiling as imageCacheBudgetBytes's own `ceiling`. See
  // lib/services/image_pipeline/cache_budget.dart for the sizing rationale.
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      imageCacheBudgetBytes(physicalMemoryBytes: null);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureImageCache();
  // Composition root: injects the real RAW decoder. When dngDecoder is null
  // (tests, and any platform without the native dylib) a DNG carrying no
  // embedded preview is a PERMANENT MISS -- there is no legacy decode channel
  // left to fall back to; it was deleted in M6. See the dngDecoder comment in
  // AppState's constructor.
  // The DISPATCHING decoder, not the RAW-only one: this single argument is
  // what makes TIFF reach pixels in the detail view AND in the export path,
  // because AppState forwards the same value into PhotoExportService and into
  // ImagePreloadController.
  final appState = AppState(
    dngDecoder: halcyonFullDecoder,
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
        extensions: const <ThemeExtension<dynamic>>[HalcyonTokens.light],
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
        extensions: const <ThemeExtension<dynamic>>[HalcyonTokens.dark],
        useMaterial3: true,
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
