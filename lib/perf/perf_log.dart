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
import 'dart:io';

import 'package:flutter/painting.dart';

import '../services/image_pipeline/photo_payload_cache.dart' show kPayloadByteBudget;

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

class PerfLog {
  static final Stopwatch _sw = Stopwatch()..start();
  static final List<String> _buf = <String>[];
  static String? _path;
  static Timer? _flushTimer;
  static bool enabled = false;

  /// Called by the view instrumentation when the decoded image for [id]
  /// becomes available. The driver awaits this.
  static void Function(String id)? onImageReady;

  static int get us => _sw.elapsedMicroseconds;

  static void init(String outPath) {
    enabled = true;
    _path = outPath;
    final f = File(outPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('');
    // Periodic sync flush: keeps the log durable without adding file I/O
    // inside the measured spans.
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
      '|kPayloadByteBudget=$kPayloadByteBudget',
    );
  }

  static void log(String s) {
    if (!enabled) return;
    final line = 'PERF|${_sw.elapsedMicroseconds}|$s';
    _buf.add(line);
    // ignore: avoid_print
    print(line);
    if (_buf.length >= 200) flushSync();
  }

  static void flushSync() {
    if (_path == null || _buf.isEmpty) return;
    final chunk = _buf.join('\n');
    _buf.clear();
    File(_path!).writeAsStringSync('$chunk\n', mode: FileMode.append);
  }

  static Future<void> flush() async {
    _flushTimer?.cancel();
    flushSync();
    await stdout.flush();
  }
}
