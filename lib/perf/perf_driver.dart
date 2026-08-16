// PERMANENT PERF HARNESS (contract: docs/logs/2026-08-16/round-3-implementation-plan.md §3).
//
// Drives the REAL app stack (real MethodChannel -> real AppDelegate.swift,
// real engine decode, real raster) through N photo switches and logs
// per-stage timestamps. A structural no-op unless HALCYON_PERF_DIR is set --
// see PerfDriver.active, only reached from main.dart behind that same check.
//
// The macOS build is sandboxed: HALCYON_PERF_DIR/HALCYON_PERF_OUT must be
// RELATIVE paths (resolved against the app container's Data dir), never
// absolute paths outside the sandbox -- those throw PathAccessException.
//
// Env vars:
//   HALCYON_PERF_DIR   folder of photos to load (required to activate)
//   HALCYON_PERF_OUT   log file path (default tmp/verify/perf/run.log)
//   HALCYON_PERF_N     switches per pass (default 24)
//   HALCYON_PERF_PACE  ms to wait after a switch settles, paced pass (default 1200)
//   HALCYON_PERF_MODE  "paced" | "rapid" | "both" (default both)
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

import '../providers/app_state.dart';
import '../services/native_thumbnail_service.dart';
import 'perf_log.dart';

class PerfDriver {
  static bool get active => Platform.environment['HALCYON_PERF_DIR'] != null;

  static String get _dir => Platform.environment['HALCYON_PERF_DIR']!;
  static String get _out =>
      Platform.environment['HALCYON_PERF_OUT'] ??
      '/Users/jhangyu/project/Halcyon/tmp/verify/perf/run.log';
  static int get _n => int.parse(Platform.environment['HALCYON_PERF_N'] ?? '24');
  static int get _pace =>
      int.parse(Platform.environment['HALCYON_PERF_PACE'] ?? '1200');
  static String get _mode => Platform.environment['HALCYON_PERF_MODE'] ?? 'both';

  static Completer<void>? _waiter;
  static String? _waitId;

  static void notifyImageReady(String id) {
    if (_waitId != null && id == _waitId && !(_waiter?.isCompleted ?? true)) {
      _waiter!.complete();
    }
  }

  static Future<void> run(AppState state) async {
    await runZonedGuarded(() => _run(state), (e, s) {
      PerfLog.log('driver.error|$e');
      PerfLog.flushSync();
    });
  }

  static Future<void> _run(AppState state) async {
    PerfLog.init(_out);
    Timer.periodic(const Duration(seconds: 1), (t) {
      PerfLog.log('heartbeat');
    });
    PerfLog.onImageReady = notifyImageReady;
    PerfLog.log('driver.config|dir=$_dir|n=$_n|pace=$_pace|mode=$_mode');

    // Frame timings (H4: main-thread / raster jank).
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        final b = t.buildDuration.inMicroseconds;
        final r = t.rasterDuration.inMicroseconds;
        final total = t.totalSpan.inMicroseconds;
        if (total > 20000) {
          PerfLog.log('frame.slow|build=$b|raster=$r|total=$total');
        }
      }
    });

    await Future<void>.delayed(const Duration(milliseconds: 2500));

    PerfLog.log('folder.load.begin|$_dir');
    final tLoad = PerfLog.us;
    await state.loadFolder(Directory(_dir));
    PerfLog.log(
      'folder.load.end|items=${state.items.length}|dur=${PerfLog.us - tLoad}',
    );
    if (state.items.length < 5) {
      PerfLog.log('driver.abort|not enough items');
      await _finish();
      return;
    }

    // Let the initial preload window fill completely.
    await Future<void>.delayed(const Duration(milliseconds: 4000));
    PerfLog.log('driver.warmup.done');

    if (_mode == 'paced' || _mode == 'both') {
      await _pass(state, 'paced', _pace);
    }
    if (_mode == 'rapid' || _mode == 'both') {
      await _pass(state, 'rapid', 0);
    }
    if (_mode == 'burst' || _mode == 'both') {
      await _burst(state);
    }

    await _microbench(state);
    await _finish();
  }

  static Future<void> _pass(AppState state, String label, int paceMs) async {
    // Reset to the first item and let the window refill.
    state.selectItem(state.items.first.id);
    await Future<void>.delayed(const Duration(milliseconds: 4000));
    PerfLog.log('pass.begin|$label');

    final count = _n.clamp(1, state.items.length - 1);
    for (var i = 0; i < count; i++) {
      final idx = state.items.indexWhere((e) => e.id == state.selectedItemID);
      if (idx < 0 || idx + 1 >= state.items.length) break;
      final nextId = state.items[idx + 1].id;

      _waitId = nextId;
      _waiter = Completer<void>();
      final t0 = PerfLog.us;
      PerfLog.log('switch.begin|$label|$i|$nextId');
      state.nextPhoto();
      try {
        await _waiter!.future.timeout(const Duration(seconds: 15));
        PerfLog.log('switch.end|$label|$i|$nextId|dur=${PerfLog.us - t0}');
      } on TimeoutException {
        PerfLog.log('switch.timeout|$label|$i|$nextId|dur=${PerfLog.us - t0}');
      }
      _waitId = null;
      if (paceMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: paceMs));
      } else {
        // Yield one frame so the pipeline can present before the next key.
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    PerfLog.log('pass.end|$label');
  }

  /// H2: fire arrow keys at a fixed interval WITHOUT waiting for the image to
  /// be ready, i.e. the user outruns the preloader. Measures cache hit rate and
  /// how long the spinner (view.spinner) is on screen.
  static Future<void> _burst(AppState state) async {
    final gap = int.parse(
      Platform.environment['HALCYON_PERF_BURST_MS'] ?? '80',
    );
    state.selectItem(state.items.first.id);
    await Future<void>.delayed(const Duration(milliseconds: 4000));
    PerfLog.log('pass.begin|burst|gap=$gap');
    final count = _n.clamp(1, state.items.length - 1);
    for (var i = 0; i < count; i++) {
      final idx = state.items.indexWhere((e) => e.id == state.selectedItemID);
      if (idx < 0 || idx + 1 >= state.items.length) break;
      PerfLog.log('burst.key|$i|${state.items[idx + 1].id}');
      state.nextPhoto();
      await Future<void>.delayed(Duration(milliseconds: gap));
    }
    PerfLog.log('burst.keysDone');
    // Wait for the pipeline to settle and record when the final image lands.
    final finalId = state.selectedItemID!;
    _waitId = finalId;
    _waiter = Completer<void>();
    final t0 = PerfLog.us;
    try {
      await _waiter!.future.timeout(const Duration(seconds: 20));
      PerfLog.log('burst.settled|$finalId|afterKeys=${PerfLog.us - t0}');
    } on TimeoutException {
      PerfLog.log('burst.timeout|$finalId|afterKeys=${PerfLog.us - t0}');
    }
    _waitId = null;
    PerfLog.log('pass.end|burst');
  }

  /// Isolated component costs, measured outside the widget pipeline:
  ///  - native channel roundtrip (H2/H3)
  ///  - engine JPEG decode (H1)
  static Future<void> _microbench(AppState state) async {
    PerfLog.log('microbench.begin');
    final files = Directory(_dir)
        .listSync()
        .whereType<File>()
        .where((f) => !f.uri.pathSegments.last.startsWith('.'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (var i = 0; i < files.length && i < 12; i++) {
      final path = files[i].path;
      final t0 = PerfLog.us;
      final bytes = await NativeThumbnailService.getThumbnail(
        path,
        purpose: ImageRequestPurpose.preview,
      );
      final t1 = PerfLog.us;
      PerfLog.log(
        'micro.channel|$i|${bytes?.length ?? -1}|roundtrip=${t1 - t0}',
      );
      if (bytes == null) continue;

      // Engine decode of the same bytes (what Image.memory does internally).
      final t2 = PerfLog.us;
      final codec = await ui.instantiateImageCodec(bytes);
      final t3 = PerfLog.us;
      final frame = await codec.getNextFrame();
      final t4 = PerfLog.us;
      PerfLog.log(
        'micro.decode|$i|${frame.image.width}x${frame.image.height}'
        '|codec=${t3 - t2}|frame=${t4 - t3}|total=${t4 - t2}',
      );

      // Decode downscaled to a typical viewport width (what a cacheWidth
      // hint would cost instead).
      final t5 = PerfLog.us;
      final codec2 = await ui.instantiateImageCodec(bytes, targetWidth: 1800);
      final f2 = await codec2.getNextFrame();
      final t6 = PerfLog.us;
      PerfLog.log(
        'micro.decode1800|$i|${f2.image.width}x${f2.image.height}'
        '|total=${t6 - t5}',
      );
      f2.image.dispose();
      codec2.dispose();
      frame.image.dispose();
      codec.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    // Raw file read cost, for reference (H3 denominator).
    for (var i = 0; i < files.length && i < 6; i++) {
      final t0 = PerfLog.us;
      final b = await files[i].readAsBytes();
      PerfLog.log('micro.fileread|$i|${b.length}|dur=${PerfLog.us - t0}');
    }
    PerfLog.log('microbench.end');
  }

  static Future<void> _finish() async {
    PerfLog.log('driver.done');
    await PerfLog.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }
}
