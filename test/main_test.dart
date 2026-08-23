import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/main.dart';

void main() {
  testWidgets(
    'configureImageCache raises ImageCache.maximumSizeBytes to 768 MiB '
    '(default 100MB only fits ~1 full-frame decode)',
    (tester) async {
      configureImageCache();
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        805306368,
        reason:
            '768 MiB pinned as a RAW BYTE COUNT on purpose: the round-1 record '
            'lost time to MB-vs-MiB drift, and 768 decimal MB (768000000) is a '
            'different number that would still look right in a review',
      );
    },
  );
}
