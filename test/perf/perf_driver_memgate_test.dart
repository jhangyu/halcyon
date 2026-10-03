import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_driver.dart';

void main() {
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
