// Amendment-3 scheduling controls. This historical-lane file is committed on
// top of untouched production 0e6407e so its RED is a genuine pre-fix result.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

// Drains SYNCHRONOUSLY instead of waiting for a real (disabled-by-default
// in AutomatedTestWidgetsFlutterBinding) frame -- see REPAIR 3 /
// publication_pacer.dart: the paced tier-1/tier-2 publish queue only
// drains when its frame hook fires, and a plain test() never pumps a real
// frame on its own. The pacer re-arms itself after each drained item, so
// a synchronous hook fully drains the queue before submit() returns.
void _microtaskFrame(void Function() callback) => callback();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> items(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
  });

  // Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
  // debug-only identity short-circuit asserts sampled alpha is opaque.
  // Same repair as commits 253b89f / d43c2a1.
  DecodedRgba decoded() {
    final rgba = Uint8List(2 * 2 * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 0xFF;
    }
    return DecodedRgba(rgba: rgba, width: 2, height: 2);
  }

  Future<void> until(bool Function() condition, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for: ${reason ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // `_finishOffLane`'s encode continuation is deliberately unawaited by the
  // controller (it has no caller). If a test ends -- and `addTearDown`
  // disposes the controller -- while that continuation is still in flight,
  // its later `_inflight.release(...)` races the disposed budget's `clear()`
  // and trips a cross-test assertion (attributed to whatever test happens to
  // be running when it lands). Poll `debugInflightBytes` to zero before
  // ending a test that used an expensive/RAW controller.
  Future<void> settle(ImagePreloadController controller) => until(
    () => controller.debugInflightBytes == 0,
    reason: 'controller inflight-bytes budget to drain before teardown',
  );

  // This is the scheduling killer: all three +/-1 items become eligible after
  // the frozen 250ms debounce, but no-preview RAW execution must be SERIAL.
  // At 0e6407e the tier-two loop uses unawaited(_ensurePayload(...).then(...))
  // for every item, so the 120ms decoder futures overlap and this assertion is
  // a real red pre-fix observation, not a timeout or setup failure.
  test('TC-086 expensive post-debounce RAW execution is sequential', () async {
    var concurrent = 0;
    var maxConcurrent = 0;
    var started = 0;
    final controller = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        started++;
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        concurrent--;
        return decoded();
      },
    );
    addTearDown(controller.dispose);

    final photos = items(14);
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[5].id,
      notifyLoaded: () {},
    );
    await until(() => started == 3, reason: 'all +/-1 expensive decodes began');
    await until(() => concurrent == 0, reason: 'all expensive decodes settled');

    expect(
      maxConcurrent,
      1,
      reason:
          'all three eligible RAW items may retain under -3..+5, but only '
          'one native RAW decode may execute after the frozen debounce',
    );
    // `debugInflightBytes` alone can read 0 transiently BETWEEN two serial
    // items (nothing acquired yet for the next one), so it is not a valid
    // "the whole retention window is done" signal on its own here: wait for
    // every -3..+5 slot to actually have landed a payload first.
    await until(
      () => List.generate(9, (i) => photos[2 + i].id).every(
        (id) => controller.payloadFor(id) != null,
      ),
      reason: 'the whole -3..+5 retention window to finish its serial decode',
    );
    await settle(controller);
  });

  // Cheap work retains the opposite scheduling rule: the full retention-window
  // loads launch in parallel rather than being serialised behind the selected
  // item. The selected call is completed first so the test observes the later
  // eight-window fan-out, not merely the deliberate priority phase.
  test('TC-088 cheap and expensive payloads retain identically at -3 and '
      'evict identically at -4', () async {
    Future<ImagePreloadController> make(bool expensive) async {
      return ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async => expensive
            ? const NativeImageNeedsRawDecode(exifOrientation: 1)
            : NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])),
        dngDecoder: expensive ? (path) async => decoded() : null,
      );
    }

    final photos = items(20);
    for (final expensive in [false, true]) {
      final controller = await make(expensive);
      addTearDown(controller.dispose);
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[2].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor(photos[2].id) != null,
        reason: '${expensive ? 'expensive' : 'cheap'} source landed',
      );
      final payload = controller.payloadFor(photos[2].id);

      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[5].id,
        notifyLoaded: () {},
      );
      expect(
        identical(controller.payloadFor(photos[2].id), payload),
        isTrue,
        reason: '${expensive ? 'expensive' : 'cheap'} survives exactly at -3',
      );

      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[6].id,
        notifyLoaded: () {},
      );
      expect(
        controller.payloadFor(photos[2].id),
        isNull,
        reason: '${expensive ? 'expensive' : 'cheap'} evicts immediately at -4',
      );
      if (expensive) await settle(controller);
    }
  });

  test('TC-089 cheap full retention-window source loads overlap', () async {
    var concurrent = 0;
    var maxConcurrent = 0;
    final first = Completer<NativeImageResult>();
    var isFirst = true;
    var firstRequested = false;
    final controller = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) {
        if (isFirst) {
          isFirst = false;
          firstRequested = true;
          return first.future;
        }
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        return Future<NativeImageResult>.delayed(
          const Duration(milliseconds: 80),
          () {
            concurrent--;
            return NativeImageBytes(Uint8List.fromList([137, 80, 78, 71]));
          },
        );
      },
    );
    addTearDown(controller.dispose);
    final photos = items(14);
    final preload = controller.preloadImages(
      items: photos,
      selectedItemId: photos[5].id,
      notifyLoaded: () {},
    );
    // Wait on the REAL signal that the priority (first) load has been invoked,
    // not a fixed event-loop turn: preloadImages reaches this loader only after
    // an async content probe, so on a loaded runner one `Duration.zero` turn can
    // fire before `first` exists to be completed. `until` fails loudly on
    // timeout. Positive, pollable condition -> convertible.
    await until(() => firstRequested,
        reason: 'priority (first) loader has been requested');
    first.complete(NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])));
    await preload;
    expect(
      maxConcurrent,
      greaterThan(1),
      reason: 'cheap payload acquisition across -3..+5 must overlap',
    );
  });
}
