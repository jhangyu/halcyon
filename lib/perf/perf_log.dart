// NOTE (2026-08-24 user directive): UI-driven measurement runs that consume this
// instrumentation (via PerfDriver) are USER-run only — agents must not launch them.
// See lib/perf/perf_driver.dart deprecation header and
// docs/logs/2026-08-24/m4-m6-convergence-contract.md AC4.
//
// PERMANENT PERF INSTRUMENTATION (contract: docs/logs/2026-08-16/round-3-implementation-plan.md §3).
// Gated on the HALCYON_PERF_DIR environment variable: unset (the normal shipping
// case) means `enabled` stays false and log() returns before any timing, buffering,
// or file I/O -- a structural no-op, not merely a disabled feature.
// The event names and `key=value` field shapes this writes (`PERF|<us>|<name>|...`)
// are a stable output format for downstream perf-log parsing tooling -- do not
// rename/reshape events without checking that any such tooling still parses them.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import '../services/image_pipeline/photo_payload_cache.dart' show kPayloadByteBudget;

// D1 (docs/logs/2026-09-04/jank-instrumentation-contract.md): a second,
// simpler activation path for a plain `flutter run --dart-define=
// HALCYON_PERF_LOG=1`, distinct from PerfDriver's HALCYON_PERF_DIR-gated
// benchmark harness (deprecated for agent use, user-run only -- see the
// header note above). This flag only turns on event logging + frame-overrun
// timings for an ordinary interactive session; it never drives synthetic
// photo switches. `const` so the guard is tree-shakable when false.
// `bool.fromEnvironment` is true ONLY for the literal string "true", so the
// documented `=1` invocation would silently no-op; accept both spellings.
const String _perfLogEnv = String.fromEnvironment('HALCYON_PERF_LOG');
const bool kPerfLog = _perfLogEnv == '1' || _perfLogEnv == 'true';

// Build-commit stamp (round-1 parking-lot P-2). Injected via
// `--dart-define=HALCYON_BUILD_COMMIT=$(git rev-parse HEAD)` at build time;
// defaults to 'unknown' for a plain `flutter run` or a build that did not
// pass the define -- this is a --dart-define, not a generated file, because
// it needs zero changes to scripts/build_apps.py to be usable by hand and
// degrades safely (an honest 'unknown', never a stale value) when the
// builder does not wire it in. Wiring scripts/build_apps.py to pass this
// automatically is a follow-up outside this file's ownership.
const String kHalcyonBuildCommit = String.fromEnvironment(
  'HALCYON_BUILD_COMMIT',
  defaultValue: 'unknown',
);

/// Pure delta-tracking logic for the D3 stall probe, factored out of
/// [PerfLog._startStallProbe] so it is unit-testable without a real `Timer`.
///
/// The probe fires every [intervalMs]; each fire is expected to have
/// advanced the stopwatch by exactly [intervalMs]. Round-2 remediation
/// (residual-jank-diagnosis.md fix #6/stall-probe): [expectedMs] used to
/// accumulate forever from `t=0`, so once one stall pushed the stopwatch
/// ahead of schedule, EVERY subsequent tick reported the same growing
/// cumulative drift instead of the length of that one gap -- coalesced ticks
/// (e.g. the timer catching up after a long stall) would each re-log the
/// same total. [tick] now resyncs [expectedMs] to the actual elapsed time
/// whenever it logs, so the next call reports only the NEW gap.
class StallProbeCalculator {
  StallProbeCalculator({this.intervalMs = 8, this.thresholdMs = 16});

  final int intervalMs;
  final int thresholdMs;

  int _expectedMs = 0;

  @visibleForTesting
  int get debugExpectedMs => _expectedMs;

  /// Call once per probe fire with the stopwatch's current elapsed
  /// milliseconds. Returns the drift to log, or `null` if within budget.
  int? tick(int elapsedMs) {
    _expectedMs += intervalMs;
    final driftMs = elapsedMs - _expectedMs;
    if (driftMs > thresholdMs) {
      // Resync: the NEXT tick's drift is measured against "now", not against
      // the schedule from before the stall, so a stall's own duration is
      // logged once as a single per-gap value.
      _expectedMs = elapsedMs;
      return driftMs;
    }
    return null;
  }
}

class PerfLog {
  static final Stopwatch _sw = Stopwatch()..start();
  static final List<String> _buf = <String>[];
  static Timer? _flushTimer;
  static bool enabled = false;

  /// Round-1 review fix (HIGH, measurement validity): writes now go through a
  /// buffered async [IOSink] instead of a repeated `writeAsStringSync`, so
  /// flushing never blocks the UI isolate on file I/O.
  static IOSink? _sink;

  /// D1 round-2 (user-approved addition): mirror events into dart:developer
  /// Timeline so they appear in a DevTools flame chart when the user records
  /// with `--profile`. Gated SEPARATELY from [enabled] -- only
  /// [initForInteractiveSession] (the HALCYON_PERF_LOG path) turns this on,
  /// not PerfDriver's HALCYON_PERF_DIR path, per the lead's instruction to
  /// gate it "exactly like the file logging" for THIS activation path only.
  static bool _timelineMirror = false;

  /// D3 (docs/logs/2026-09-04/occupancy-attribution-contract.md): occupancy
  /// attribution needs to tell "which isolate did this work happen on"
  /// apart, so [log] tags every event with the current isolate's identity.
  /// Cached after first read -- an isolate's `debugName` never changes for
  /// its lifetime, so re-reading `Isolate.current` on every event would be
  /// pure waste on the hot event path.
  static String? _isoTagCache;

  /// Cheap, allocation-free-after-first-call helper returning e.g.
  /// `iso=main` or `iso=worker:<name>`. Only ever invoked from [log], which
  /// already gates on [enabled] before reaching this.
  static String isoTag() {
    final cached = _isoTagCache;
    if (cached != null) return cached;
    final name = Isolate.current.debugName;
    final tag = (name == null || name.isEmpty || name == 'main')
        ? 'iso=main'
        : 'iso=worker:$name';
    _isoTagCache = tag;
    return tag;
  }

  /// D3 stall probe: periodic timer on the isolate that calls
  /// [initForInteractiveSession] (the UI isolate). Compares actual elapsed
  /// time against the expected tick count; if the isolate's event loop was
  /// occupied by non-frame work long enough that this timer's fire was
  /// delayed past the 16ms threshold, that drift IS the direct measurement
  /// of "UI isolate blocked" the occupancy-attribution campaign needs.
  /// O(1) per tick, no allocation unless it actually logs.
  static Timer? _stallTimer;

  /// Called by the view instrumentation when the decoded image for [id]
  /// becomes available. The driver awaits this.
  static void Function(String id)? onImageReady;

  static int get us => _sw.elapsedMicroseconds;

  static void init(String outPath, {int payloadByteBudget = kPayloadByteBudget}) {
    // Round-1 review fix (LOW): cancel any previous timer/sink before
    // reassigning, so a second `init()` (e.g. HALCYON_PERF_LOG and
    // HALCYON_PERF_DIR both set) cannot leak a running periodic timer.
    _flushTimer?.cancel();
    _stallTimer?.cancel();
    unawaited(_sink?.close());
    enabled = true;
    final f = File(outPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('');
    // Buffered async sink (round-1 review fix, HIGH): opened once, written to
    // on the 300ms timer below -- never a sync file write on the event path.
    _sink = f.openWrite(mode: FileMode.writeOnlyAppend);
    // Periodic flush: keeps the log durable without adding file I/O inside
    // the measured spans.
    _flushTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      flushSync();
    });
    log('perf.init|$outPath');
    // Version stamp (round-1 parking-lot P-2): with UI switch-latency
    // measurement now user-run rather than agent-run, "which code is this
    // binary" stopped being something an agent's build-event log could
    // guarantee and became something the USER has to remember -- and on the
    // cheap (preview-bearing) sample corpus, a stale binary reads as a
    // FASTER number, which looks like good news and trips no sanity check
    // (see docs/logs/2026-08-24/round-1-m4-handoff.md §7 PL-5 note). This
    // line makes the binary self-report its own provenance instead.
    log(
      'build.stamp|commit=$kHalcyonBuildCommit'
      '|imageCacheMaxBytes=${PaintingBinding.instance.imageCache.maximumSizeBytes}'
      '|kPayloadByteBudget=$payloadByteBudget',
    );
  }

  /// D1 entry point for the `HALCYON_PERF_LOG` interactive path (AC5): opens
  /// the log next to the system temp dir, prints the path to console (AC3
  /// requires it be discoverable at startup) and registers a frame-timings
  /// callback that logs any frame over the 17ms (60fps) budget. Callers must
  /// still gate the call itself on [kPerfLog] -- this method does not
  /// re-check it, so it stays a plain no-op-free function for tests.
  static void initForInteractiveSession() {
    _timelineMirror = true;
    final outPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'halcyon_perf_$pid.log';
    init(outPath);
    // ignore: avoid_print
    print('HALCYON_PERF_LOG active -- writing to $outPath');
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        final buildUs = t.buildDuration.inMicroseconds;
        final rasterUs = t.rasterDuration.inMicroseconds;
        final totalUs = t.totalSpan.inMicroseconds;
        // 17ms budget (~60fps), matching AC3's "frame_overrun" marker.
        if (totalUs > 17000) {
          log(
            'frame_overrun|build_ms=${buildUs / 1000}'
            '|raster_ms=${rasterUs / 1000}|total_ms=${totalUs / 1000}',
          );
        }
      }
    });
    _startStallProbe();
  }

  /// D3: starts the 8ms periodic stall probe on whichever isolate calls
  /// this (always the UI isolate -- only [initForInteractiveSession] calls
  /// it). Any previous timer is cancelled first so a second call (e.g. a
  /// stray double-init) cannot leak a running periodic timer, matching the
  /// existing [_flushTimer] discipline in [init].
  static void _startStallProbe() {
    _stallTimer?.cancel();
    final probeSw = Stopwatch()..start();
    final calc = StallProbeCalculator();
    _stallTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      final driftMs = calc.tick(probeSw.elapsedMilliseconds);
      // Preformat only when actually logging -- happy path is a single
      // integer subtraction + comparison, no allocation.
      if (driftMs != null) {
        log('stall|ms=$driftMs');
      }
    });
  }

  /// Test-only observation seam.
  ///
  /// Consulted BEFORE the [enabled] gate below, and that placement is
  /// load-bearing: `log()` returns immediately when the perf log has not been
  /// initialised, which is the state every unit test runs in. A sink consulted
  /// after the gate would observe nothing, making any assertion against it
  /// vacuous (it would pass against an always-empty list).
  ///
  /// Assert on this rather than capturing `debugPrint`, which is process-wide
  /// and order-dependent across the suite.
  @visibleForTesting
  static void Function(String line)? testSink;

  static void log(String s) {
    testSink?.call(s);
    if (!enabled) return;
    // D3: tag every event with `iso=` -- a superset of the contract's
    // "decode/normalize/publish phase events" requirement (AC3), since all
    // of those call through this shared sink and there is no cheaper way to
    // guarantee no call site is missed than tagging at the one choke point.
    final line = 'PERF|${_sw.elapsedMicroseconds}|$s|${isoTag()}';
    _buf.add(line);
    // Round-1 review fix (HIGH, measurement validity): the per-event
    // `print()` and the every-200-events sync file flush were both removed
    // from this hot path -- on the UI isolate, at the event rates this
    // instrumentation now produces (per-normalize, per-publish, per-submit),
    // they were manufacturing the very frame_overruns this campaign is
    // trying to measure. Durability now comes ONLY from the 300ms
    // `Timer.periodic` in [init] (buffered async [IOSink], not sync I/O) plus
    // the explicit [flush] callers already invoke at shutdown/error time.
    //
    // D1 round-2: mirror into the DevTools Timeline. This call-site-shared
    // `log()` has no notion of matched start/end pairs (callers just log two
    // independent lines, e.g. `req_start`/`req_end`), so every event mirrors
    // as an INSTANT event rather than a properly nested span. Round-1 review
    // fix: no `split()` + no per-event arguments map (was the cheapest option
    // the reviewer offered) -- name every mirrored event `'perf'` and rely on
    // the buffered log file for per-event detail; DevTools still shows WHEN
    // events fired on the timeline even without a per-event label.
    if (_timelineMirror) {
      developer.Timeline.instantSync('perf');
    }
  }

  static void flushSync() {
    final sink = _sink;
    if (sink == null || _buf.isEmpty) return;
    final chunk = _buf.join('\n');
    _buf.clear();
    // Buffered write on an already-open IOSink: does not block the calling
    // isolate the way `File.writeAsStringSync` did.
    sink.write('$chunk\n');
  }

  static Future<void> flush() async {
    _flushTimer?.cancel();
    _stallTimer?.cancel();
    flushSync();
    await _sink?.flush();
    await stdout.flush();
  }

  /// Closes the underlying file sink, releasing its OS file handle.
  ///
  /// [flush] alone never did this -- it only flushes buffered bytes and
  /// cancels timers, leaving `_sink` open (by design: a live interactive
  /// session calls [flush] periodically without wanting to lose its sink).
  /// On Windows this open handle keeps the log file (and therefore its
  /// parent directory) locked, so a test's `tearDown` that does
  /// `await PerfLog.flush(); ...; tmpDir.deleteSync(recursive: true);`
  /// throws `PathAccessException` (errno 32, "used by another process") --
  /// POSIX (macOS/Linux) allows deleting a file/dir with an open handle, so
  /// this was invisible outside CI's windows-latest runner. Callers that
  /// need the file handle released (tests deleting their temp dir; a real
  /// shutdown path) must call this in addition to [flush].
  static Future<void> close() async {
    await flush();
    final sink = _sink;
    _sink = null;
    await sink?.close();
  }
}
