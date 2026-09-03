// Deliverable 2, plumbing half: the gate injected at the composition root
// actually reaches every compositing call on the decode-completion path.
// TC-902 / TC-903.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

/// Counts slot requests and opens them immediately, so a test can assert
/// "the gate was consulted" without also having to drive completion order.
class CountingGate {
  int requests = 0;
  Future<void> call() {
    requests++;
    return Future<void>.value();
  }
}

/// 2x2, orientation 6 (a real GPU pass), OPAQUE.
DecodedRgba _decoded() {
  final bytes = Uint8List(2 * 2 * 4);
  for (var p = 0; p < 4; p++) {
    bytes[p * 4] = 10 + p * 20;
    bytes[p * 4 + 3] = 0xFF;
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 2);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-902
  test('PhotoSource forwards its gate to both provider calls', () async {
    final gate = CountingGate();
    final source = PhotoSource(
      loader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 6),
      dngDecoder: (path) async => _decoded(),
      compositeGate: gate.call,
    );

    final decode = await source.decodePhaseExpensive(
      '/tmp/whatever.dng',
      longEdge: 1, // forces the pixel path past its short-circuit too
      exifOrientation: 6,
    );

    expect(decode.pixels, isNotNull);
    expect(
      gate.requests,
      2,
      reason: 'one slot for the pixel payload pass, one for the full-res pass',
    );
    decode.fullRes?.image?.dispose();
  });

  // TC-903
  test('ImagePreloadController forwards its gate to PhotoSource', () async {
    final tmpDir = await Directory.systemTemp.createTemp('gate_test');
    addTearDown(() => tmpDir.delete(recursive: true));
    final file = File('${tmpDir.path}/x.dng');
    await file.writeAsBytes(<int>[0, 1, 2, 3]);

    final gate = CountingGate();
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 6),
      dngDecoder: (path) async => _decoded(),
      payloadEncoder: null,
      compositeGate: gate.call,
    );
    addTearDown(controller.dispose);
    expect(controller.debugCompositeGateIsPaced, isTrue);

    await controller.preloadImages(
      items: [PhotoItem(id: 'x', files: [file])],
      selectedItemId: 'x',
      notifyLoaded: () {},
    );
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(
      gate.requests,
      greaterThan(0),
      reason: 'the injected gate must reach the decode-completion path',
    );
  });
}
