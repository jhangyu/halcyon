import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/main.dart';

void main() {
  testWidgets(
    'configureImageCache raises ImageCache.maximumSizeBytes to 500MB '
    '(AC4: default 100MB only fits ~1 full-frame decode)',
    (tester) async {
      configureImageCache();
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        500 << 20,
      );
    },
  );
}
