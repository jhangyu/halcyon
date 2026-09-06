import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/stage_widths.dart';

Future<NativeImageResult> _noLoad(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageFailure('unsupported', 'test stub');

void main() {
  late List<int> poolPushes;
  late void Function(int) savedSink;

  setUp(() {
    poolPushes = <int>[];
    savedSink = ImagePreloadController.decodePoolWidthSink;
    ImagePreloadController.decodePoolWidthSink = poolPushes.add;
  });

  tearDown(() {
    ImagePreloadController.decodePoolWidthSink = savedSink;
  });

  test('TC-1024: construction derives every stage width from one number', () {
    final controller = ImagePreloadController(
      imageLoader: _noLoad,
      decodeLaneWidth: 3,
    );
    addTearDown(controller.dispose);

    expect(controller.stageWidths, StageWidths.derive(3));
    expect(controller.decodeLaneWidth, 3);
    expect(controller.debugEncodeStageWidth, kSecondaryStageWidth);
    expect(controller.debugDeriveQueueWidth, kSecondaryStageWidth);
    expect(poolPushes, [3], reason: 'the pool is pushed the lane-read value');
  });

  test('TC-1025: setDecodeLaneWidth re-derives and pushes every stage', () {
    final controller = ImagePreloadController(
      imageLoader: _noLoad,
      decodeLaneWidth: 1,
    );
    addTearDown(controller.dispose);
    poolPushes.clear();

    controller.setDecodeLaneWidth(5);
    expect(controller.stageWidths, StageWidths.derive(5));
    expect(controller.decodeLaneWidth, 5);
    expect(controller.debugEncodeStageWidth, kSecondaryStageWidth);
    expect(controller.debugDeriveQueueWidth, kSecondaryStageWidth);
    expect(poolPushes, [5]);

    // Out-of-range clamps once, at StageWidths.derive.
    controller.setDecodeLaneWidth(0);
    expect(controller.decodeLaneWidth, 1);

    // A redundant request still pushes: TC-938/TC-966 pin push-on-every-call
    // as the pool's contract (`pushed.last` must be THIS call's clamped
    // width), so `_applyStageWidths` carries no equality short-circuit.
    poolPushes.clear();
    controller.setDecodeLaneWidth(1);
    expect(poolPushes, [1]);
  });
}
