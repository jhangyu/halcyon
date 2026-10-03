import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_driver.dart';

void main() {
  _completionTests();
  _walkTests();
  test('TC-1430 memgate sample line carries every field the D5 gate reads', () {
    final line = PerfDriver.formatMemgateSample(
      tMs: 1000,
      phase: 'idle',
      step: 26,
      liveImageBytes: 160563200,
      cacheBytes: 0,
      cacheCount: 0,
      laneWidth: 2,
      funnelCalls: null,
      deviceReleaseRuns: null,
      displayedRedecodes: null,
    );
    expect(
      line,
      'memgate|t_ms=1000|phase=idle|step=26|live_image_bytes=160563200|'
      'cache_bytes=0|cache_count=0|lane_width=2|funnel_calls=absent|'
      'device_release_runs=absent|displayed_redecodes=absent',
    );
  });

  test('TC-1430 present counters are printed as integers', () {
    final line = PerfDriver.formatMemgateSample(
      tMs: 2,
      phase: 'walk',
      step: 3,
      liveImageBytes: 1,
      cacheBytes: 2,
      cacheCount: 3,
      laneWidth: 5,
      funnelCalls: 7,
      deviceReleaseRuns: 4,
      displayedRedecodes: 0,
    );
    expect(line, endsWith('|lane_width=5|funnel_calls=7|'
        'device_release_runs=4|displayed_redecodes=0'));
  });
}

void _completionTests() {
  testWidgets('TC-1430 completion logs done, never exits early, exits 3 at '
      '120 s', (tester) async {
    final lines = <String>[];
    final exits = <int>[];
    var flushed = 0;
    PerfDriver.memgateCompletion(
      log: lines.add,
      flush: () => flushed++,
      exitFn: exits.add,
    );
    expect(lines, hasLength(1));
    expect(lines.single, matches(RegExp(r'^memgate\|done\|t_ms=\d+$')));
    expect(flushed, 1);
    expect(exits, isEmpty);

    await tester.pump(const Duration(seconds: 119));
    expect(exits, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    expect(exits, [3]);
  });
}

void _walkTests() {
  test('TC-1430 wrap walk: 13 images, 26 steps, one jump, no backward step',
      () {
    final idx = [for (var k = 0; k < 26; k++) PerfDriver.memgateWalkIndex(13, k)];
    expect(idx.first, 0);
    expect(idx[13], 0, reason: 'step 13 lands on the first image');
    expect(idx[25], 12, reason: 'step 26 (last, 0-based 25) is the last image');
    var jumps = 0;
    for (var k = 1; k < idx.length; k++) {
      if (idx[k] == idx[k - 1] + 1) continue;
      expect(idx[k], 0, reason: 'only last->first may break +1');
      expect(idx[k - 1], 12);
      jumps++;
    }
    expect(jumps, 1);
  });

  test('TC-1430 per-step line carries step index and image id', () {
    expect(
      PerfDriver.formatMemgateStep(tMs: 7, step: 13, id: 'a.raf'),
      'memgate.step|t_ms=7|step=13|id=a.raf',
    );
  });
}
