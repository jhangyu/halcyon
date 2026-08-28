import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';

void main() {
  const gib = 1 << 30;

  test('budget derivation: floor 256MiB, rung ceilings, quarter of physical',
      () {
    expect(imageCacheBudgetBytes(physicalMemoryBytes: null), 768 << 20);
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 2 * gib),
        512 << 20); // 2GiB/4
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 512 << 20),
        256 << 20); // floor: below this the M5 no-re-decode guarantee dies
  });

  // TC-334: ceiling follows the retention rung so the widened tier-1 span
  // keeps ~15% ImageCache headroom (cache-sizing-rederivation.md §3).
  test('TC-334: rung-scaled ceiling 768 / 800 / 896 MiB', () {
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 4 * gib),
        768 << 20); // floor rung, saturated old ceiling
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 11 * gib), 768 << 20);
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 12 * gib),
        800 << 20); // mid rung boundary
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 31 * gib), 800 << 20);
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 32 * gib),
        896 << 20); // high rung boundary
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 64 * gib), 896 << 20);
  });
}
