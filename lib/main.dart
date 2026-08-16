import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/app_state.dart';
import 'views/main_screen.dart';

// Flutter's ImageCache defaults to 100MB, which only fits ~1 full-frame
// decoded 24MP JPEG. Tier-1 (window resolution) + tier-2 (full size)
// precaching needs headroom for several images at once.
const int imageCacheMaxBytes = 500 << 20;

void configureImageCache() {
  PaintingBinding.instance.imageCache.maximumSizeBytes = imageCacheMaxBytes;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureImageCache();
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const HalcyonApp(),
    ),
  );
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
