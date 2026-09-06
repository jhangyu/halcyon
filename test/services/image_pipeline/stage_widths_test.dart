import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/services/image_pipeline/stage_widths.dart';

void main() {
  group('StageWidths.derive', () {
    test('TC-1020: derives every stage width from one number, secondary '
        'stages pinned at 2', () {
      for (var n = 1; n <= kMaxDecodeLaneWidth; n++) {
        final widths = StageWidths.derive(n);
        expect(widths.decodeLane, n, reason: 'decodeLane passes through');
        expect(widths.encode, 2, reason: 'encode pinned this revision');
        expect(widths.derive, 2, reason: 'derive pinned this revision');
      }
    });

    test('TC-1021: clamps the configured width once, at the source', () {
      expect(StageWidths.derive(0).decodeLane, 1);
      expect(StageWidths.derive(-5).decodeLane, 1);
      expect(
        StageWidths.derive(kMaxDecodeLaneWidth + 3).decodeLane,
        kMaxDecodeLaneWidth,
      );
      // Clamping never leaks into the secondary stages.
      expect(StageWidths.derive(0).encode, 2);
      expect(StageWidths.derive(kMaxDecodeLaneWidth + 3).derive, 2);
    });

    test('value equality holds (so a redundant push can be skipped)', () {
      expect(StageWidths.derive(4), StageWidths.derive(4));
      expect(StageWidths.derive(4).hashCode, StageWidths.derive(4).hashCode);
      expect(StageWidths.derive(4) == StageWidths.derive(5), isFalse);
    });
  });
}
