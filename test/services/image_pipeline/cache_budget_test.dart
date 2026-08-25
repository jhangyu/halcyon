import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';

void main() {
  test('budget derivation: floor 256MiB, ceiling 768MiB, quarter of physical',
      () {
    expect(imageCacheBudgetBytes(physicalMemoryBytes: null), 768 << 20);
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 32 * (1 << 30)),
        768 << 20); // capped at the measured-corpus ceiling (main.dart docs)
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 2 * (1 << 30)),
        512 << 20); // 2GiB/4
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 512 << 20),
        256 << 20); // floor: below this the M5 no-re-decode guarantee dies
  });
}
