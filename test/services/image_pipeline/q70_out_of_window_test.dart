// TC-1388/TC-1389 (q70-decouple AC2): an out-of-window deferred decode pays
// NO RGBA cost. Before this campaign the window predicate sat AFTER the
// upconvert, so every out-of-window deferred decode allocated a full w*h*4
// destination and discarded it unread.
//
// THE COUNTERS ARE THE ASSERTION. A timing- or log-based check cannot
// distinguish "no upconvert ran" from "an upconvert ran and its output was
// dropped", which is precisely the defect.
//
// Harness adapted from yuv420_direct_encode_routing_test.dart (real pool slot,
// yuv420 format, nativeAddress != 0) plus the gate-and-move-window technique
// of lane_cancellation_test.dart.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:image/image.dart' as img;

import '../../support/event_loop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 8;
  const height = 8;

  setUp(debugResetUpconvertSeam);
  tearDown(debugResetUpconvertSeam);

  Uint8List jpegBytes() => Uint8List.fromList(
    img.encodeJpg(img.Image(width: width, height: height), quality: 70),
  );

  /// Decodes item 'a' (gated), moves the selection to 'd' while 'a' is
  /// decoding, then lets 'a' finish. 'a' stays inside the retention window
  /// (so the N3 skip does not fire and its encode runs) but is outside the
  /// tier-2 band. Other items never decode (their futures never complete), so
  /// every counter belongs to 'a'.
  Future<
      ({
        int planarEncoderCalls,
        int planarReleases,
        bool payloadLanded,
        int upconverts,
        int rgbaAcquisitions,
        bool outstandingCheckouts,
      })> run() async {
    final items = [
      PhotoItem(id: 'a', files: [File('/tmp/a.dng')]),
      PhotoItem(id: 'b', files: [File('/tmp/b.dng')]),
      PhotoItem(id: 'c', files: [File('/tmp/c.dng')]),
      PhotoItem(id: 'd', files: [File('/tmp/d.dng')]),
    ];
    final gateA = Completer<void>();
    final aStarted = Completer<void>();
    var planarEncoderCalls = 0;
    var planarReleases = 0;
    final srcBytes = ceyxOutputFormatByteCount(
      CeyxOutputFormat.yuv420,
      width,
      height,
    );

    final controller = ImagePreloadController(
      decodeLaneWidth: 1,
      retention: const RetentionPolicy(
        before: 3,
        after: 3,
        payloadByteBudget: 1 << 30,
      ),
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        if (!path.endsWith('a.dng')) {
          return Completer<DecodedRgba>().future; // never opens
        }
        aStarted.complete();
        await gateA.future;
        final slot = await CeyxNativeBufferPool.shared.acquire(srcBytes);
        return DecodedRgba(
          rgba: ffi.Pointer<ffi.Uint8>.fromAddress(
            slot.address,
          ).asTypedList(srcBytes),
          width: width,
          height: height,
          format: CeyxOutputFormat.yuv420,
          nativeAddress: slot.address,
          nativeKeepAlive: slot,
          releaseNative: () {
            planarReleases++;
            CeyxNativeBufferPool.shared.release(slot);
          },
        );
      },
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async =>
              jpegBytes(),
      pointerPayloadEncoder: null,
      pointerYuv420PayloadEncoder: ({
        required nativeAddress,
        required srcCapacity,
        required width,
        required height,
        required quality,
        keepAlive,
      }) async {
        planarEncoderCalls++;
        return jpegBytes();
      },
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(32, 32);

    unawaited(
      controller.preloadImages(
        items: items,
        selectedItemId: 'a',
        notifyLoaded: () {},
      ),
    );
    await aStarted.future.timeout(const Duration(seconds: 5));
    // Window moves to 'd' (3 away: still RETAINED, so the encode
    // runs, but outside the tier-2 band) while 'a' is still decoding.
    unawaited(
      controller.preloadImages(
        items: items,
        selectedItemId: 'd',
        notifyLoaded: () {},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    gateA.complete();
    await pumpUntil(
      () => controller.debugPayloadFor('a') != null && planarReleases >= 1,
    );
    // planarReleases == 1 and no leaked checkout are negative: polling cannot
    // prove absence of a second release.
    await pumpEventLoop(8);

    return (
      planarEncoderCalls: planarEncoderCalls,
      planarReleases: planarReleases,
      payloadLanded: controller.debugPayloadFor('a') != null,
      upconverts: debugUpconvertCount,
      rgbaAcquisitions: debugUpconvertPoolAcquireCount,
      outstandingCheckouts: CeyxNativeBufferPool.shared.hasOutstandingCheckouts,
    );
  }

  // TC-1388
  test('a deferred yuv420 decode whose item left the window still yields a '
      'payload with ZERO upconverts and ZERO rgba8 pool acquisitions',
      () async {
    final r = await run();

    expect(
      r.planarEncoderCalls,
      1,
      reason: 'VACUITY GUARD: if this is 0 the fixture never took the '
          'deferred planar-encode arm and the counters below prove nothing',
    );
    expect(r.payloadLanded, isTrue,
        reason: 'the decode already ran; its payload must still land');
    expect(r.upconverts, 0, reason: 'AC2: RGBA work ran out of window');
    expect(r.rgbaAcquisitions, 0, reason: 'AC2: an rgba8 destination was '
        'acquired out of window');
  });

  // TC-1389
  test('the planar slot goes back exactly once and no pool checkout '
      'outlives the out-of-window path', () async {
    final r = await run();

    expect(r.planarEncoderCalls, 1, reason: 'vacuity guard (see TC-1388)');
    expect(r.planarReleases, 1, reason: 'planar slot released != once');
    expect(r.outstandingCheckouts, isFalse,
        reason: 'a pool slot was leaked on the out-of-window path');
  });
}
