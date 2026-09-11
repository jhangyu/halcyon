import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'memory_pressure_wiring.dart';
import 'perf/perf_driver.dart'; // PERF-INSTRUMENTATION
import 'perf/perf_log.dart'; // PERF-INSTRUMENTATION (D1)
import 'providers/app_state.dart';
import 'services/image_pipeline/cache_budget.dart';
import 'services/image_pipeline/full_decoder_dispatch.dart';
import 'services/image_pipeline/retention_policy.dart';
import 'services/platform/device_memory.dart';
import 'services/platform/open_with_channel.dart';
import 'views/layout/layout_registry.dart';
import 'views/main_screen.dart';

// Flutter's ImageCache defaults to 100MB, which only fits ~1 full-frame
// decoded 24MP JPEG. Tier-1 (window resolution) + tier-2 (full size)
// precaching needs headroom for several images at once.

void configureImageCache({
  RetentionPolicy retention = const RetentionPolicy.floor(),
  int? physicalMemoryBytes,
}) {
  // S3.1 (2026-09-11): the budget is derived from the working set the
  // retention window implies, NOT from a fraction of machine memory. The
  // memory reading, when DeviceMemory supplies one (macOS only today; null
  // everywhere else, and Platform.isX branches are forbidden by C-3), is now
  // only a downward safety ceiling. Surplus memory is deliberately left to the
  // operating system file cache, which accelerates this app's own reads. See
  // lib/services/image_pipeline/cache_budget.dart for the full derivation and
  // its attribution evidence.
  PaintingBinding.instance.imageCache.maximumSizeBytes = imageCacheBudgetBytes(
    retention: retention,
    physicalMemoryBytes: physicalMemoryBytes,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // PERF-INSTRUMENTATION (D1): interactive debug-logging path, distinct from
  // PerfDriver's benchmark harness below. `kPerfLog` is a const
  // bool.fromEnvironment('HALCYON_PERF_LOG') check, so this whole branch
  // tree-shakes out of a release build when the flag is not passed.
  if (kPerfLog) {
    PerfLog.initForInteractiveSession();
  }
  // ONE reading, taken before runApp. It must be awaited here rather than
  // fired off: AppState is constructed on the next line, and a late-arriving
  // reading would silently leave the app on the floor policy while looking
  // like it adapted. Real reading on macOS only; null (-> floor) elsewhere.
  final physicalMemoryBytes = await DeviceMemory.totalPhysicalBytes();
  // Retention is resolved FIRST because the image-cache budget is derived from
  // the retention window's slot count (S3.1), not from machine memory.
  final retention = retentionPolicyFor(
    physicalMemoryBytes: physicalMemoryBytes,
  );
  configureImageCache(
    retention: retention,
    physicalMemoryBytes: physicalMemoryBytes,
  );
  // D3 (docs/logs/2026-09-04/occupancy-attribution-contract.md): round-2
  // found the original build.stamp (in PerfLog.init) samples
  // imageCache.maximumSizeBytes BEFORE this call runs, so it always reads
  // the Flutter-default 100MB rather than the actually-configured budget.
  // This second stamp closes that gap without touching the first one.
  if (PerfLog.enabled) {
    PerfLog.log(
      'build.stamp.effective'
      '|imageCacheMaxBytes=${PaintingBinding.instance.imageCache.maximumSizeBytes}',
    );
  }
  final processors = Platform.numberOfProcessors;
  // The one line that makes the mechanism self-reporting: without it, "the
  // app adapts to this machine" is a claim about code rather than an
  // observed fact. Compared against `sysctl -n hw.memsize` on macOS.
  debugPrint(
    'startup.memory|bytes=$physicalMemoryBytes|policy=$retention'
    '|processors=$processors',
  );
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
    orientingDngDecoder: halcyonOrientingFullDecoder,
    retention: retention,
    physicalMemoryBytes: physicalMemoryBytes,
  ); // PERF-INSTRUMENTATION
  // PERF-INSTRUMENTATION (P0, docs/logs/2026-09-05/pool-round-contract.md
  // AC7 / pipeline-architecture-v2.md §5-P0): decodeLaneWidth is only known
  // once AppState's async `_initPrefs` resolves the stored pref (it is not
  // available synchronously at `build.stamp.effective` above, which fires
  // before AppState even exists) -- so this is a SEPARATE one-shot event
  // rather than an extra field appended to that earlier line. A one-shot
  // listener is the only hook available from here without reaching into
  // AppState's private `_initPrefs` (out of this task's file ownership):
  // `_initPrefs` calls `notifyListeners()` exactly once after every pref
  // (including decodeLaneWidth) is hydrated, so the first notification is
  // guaranteed to observe the resolved value.
  if (PerfLog.enabled) {
    late final VoidCallback logLaneWidthOnce;
    logLaneWidthOnce = () {
      PerfLog.log('lane.width|width=${appState.decodeLaneWidth}');
      appState.removeListener(logLaneWidthOnce);
    };
    appState.addListener(logLaneWidthOnce);
  }
  // Finder "Open With" / shell association: load the file's folder and select
  // that photo. Registered before runApp so a launch-time file isn't missed.
  OpenWithChannel.listen(appState.openPhotoAtPath);
  // Operating-system memory pressure (WP4.4 / S3.4): generous in calm, shrink
  // under pressure. Registered before runApp for the same reason as the line
  // above -- a pressure event pushed during startup is held by Flutter's
  // channel buffers and delivered as soon as this handler exists. The returned
  // responder is intentionally dropped: its lifetime is the process's.
  startMemoryPressureResponse(appState);
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
    // Watches AppState (already an ancestor provider) rather than reading a
    // constant: both the appearance mode and the layout theme are persisted
    // user settings now, so the MaterialApp has to rebuild when either
    // changes. `ThemeMode.system` remains the DEFAULT, not the hardcoding.
    final state = context.watch<AppState>();
    final layout = layoutThemeFor(state.layoutThemeId);
    return MaterialApp(
      title: 'Halcyon',
      themeMode: state.themeMode,
      theme: layout.themeDataFor(Brightness.light),
      darkTheme: layout.themeDataFor(Brightness.dark),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
