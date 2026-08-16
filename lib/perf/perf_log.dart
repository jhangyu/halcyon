// PERMANENT PERF INSTRUMENTATION (contract: docs/logs/2026-08-16/round-3-implementation-plan.md §3).
// Gated on the HALCYON_PERF_DIR environment variable: unset (the normal shipping
// case) means `enabled` stays false and log() returns before any timing, buffering,
// or file I/O -- a structural no-op, not merely a disabled feature.
// The event names and `key=value` field shapes this writes (`PERF|<us>|<name>|...`)
// are a CONTRACT consumed by scripts/tmp/perf/parse_r2.py -- do not rename/reshape
// events without checking that parser first; it must keep running unmodified.
import 'dart:async';
import 'dart:io';

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
