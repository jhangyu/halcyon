import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

/// TC-938: the user's decode-lane width reaches the persistent worker pool.
///
/// The pool is what owns worker lifetime (one dylib load per worker), so a
/// width change that stopped at `DecodeLane` would leave the pool permanently
/// at its construction width -- a silent narrowing, the defect class the P2
/// design calls out by name.
void main() {
  late List<int> pushed;
  late void Function(int) original;

  setUp(() {
    pushed = <int>[];
    original = ImagePreloadController.decodePoolWidthSink;
    ImagePreloadController.decodePoolWidthSink = pushed.add;
  });

  tearDown(() {
    ImagePreloadController.decodePoolWidthSink = original;
  });

  test('TC-938: setDecodeLaneWidth pushes the clamped width to the pool', () {
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageFailure('UNUSED', 'width wiring only'),
      decodeLaneWidth: 1,
    );
    addTearDown(controller.dispose);

    // CONSTRUCTION pushes too: before this, the pool sat at its own default
    // (2) while the lane was at the constructor's value until the stored
    // preference hydrated -- a window in which the two bounds disagreed.
    expect(pushed, [1]);

    controller.setDecodeLaneWidth(5);
    expect(controller.decodeLaneWidth, 5);
    expect(pushed, [1, 5]);

    // Below-1 values clamp, and the POOL sees the clamped value -- not the
    // raw one, or the two bounds would disagree.
    controller.setDecodeLaneWidth(0);
    expect(controller.decodeLaneWidth, 1);
    expect(pushed, [1, 5, 1]);
  });
}
