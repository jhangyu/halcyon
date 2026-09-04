import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

/// P2 folder gate. No FFI decode is cancellable, so `reset()` cannot stop an
/// in-flight expensive load -- it can only clear the maps that load is about to
/// write into. These cases pin what happens to the load that lands afterwards.
///
/// Why it matters concretely: [PhotoItem.id] is a user-controlled FILENAME, so
/// a stale failure landing after a folder switch would latch a same-named file
/// in the NEW folder as "unreadable for this session".

Future<Uint8List> _encodeRealPng(int width, int height) async {
  final rgba = Uint8List(width * height * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> makeItems() => List.generate(14, (i) {
    final id = 'IMG_${i.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
  });

  Future<Uint8List> fakeJpegEncoder(
    Uint8List rgba, {
    required int width,
    required int height,
    required int quality,
  }) => _encodeRealPng(width, height);

  /// Alpha MUST be opaque: a zero-filled buffer trips the debug-only alpha
  /// assert in decoded_rgba_image_provider.dart and turns every item into a
  /// permanent miss for a reason none of these cases is about.
  DecodedRgba opaqueDecoded() {
    final rgba = Uint8List(64 * 48 * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 0xFF;
    }
    return DecodedRgba(rgba: rgba, width: 64, height: 48);
  }

  Future<NativeImageResult> needsRawDecodeLoader(
    String path, {
    required ImageRequestPurpose purpose,
    int? targetLongEdge,
  }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

  /// Waits until [predicate] holds, or fails with [reason].
  Future<void> until(bool Function() predicate, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!predicate()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
    'TC-939 a decode superseded by a folder switch writes NO permanent miss '
    'and leaves the item re-requestable',
    () async {
      final release = Completer<void>();
      var blockedDecodeStarted = false;
      var supersede = true;

      final controller = ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) async {
          if (!supersede) return opaqueDecoded();
          blockedDecodeStarted = true;
          // Blocks until the folder has already been switched, then fails --
          // exactly what the pool's generation gate does to a superseded
          // decode (it throws CeyxPoolDiscardedException).
          await release.future;
          throw StateError('superseded decode');
        },
        payloadEncoder: fakeJpegEncoder,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      final items = makeItems();
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => blockedDecodeStarted,
        'the expensive decode never started; this case would be vacuous',
      );

      // THE FOLDER SWITCH, with the decode still in flight.
      controller.reset();
      supersede = false;
      release.complete();
      // Let the superseded decode land and be refused.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        controller.hasFailed(items[5].id),
        isFalse,
        reason:
            'a decode belonging to the PREVIOUS folder latched an id in the '
            'new one as unreadable-for-the-session',
      );
      expect(controller.payloadFor(items[5].id), isNull);

      // Re-requestable in the new generation: nothing about the refusal may
      // wedge the id (no stuck _loadingKeys claim, no hung future).
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor(items[5].id) != null,
        'the item could not be loaded again after the folder switch: the '
        'superseded decode left state behind that blocks a fresh attempt',
      );
    },
  );

  test(
    'TC-940 a SUCCESSFUL decode that lands after a folder switch is dropped, '
    'not published into the new folder',
    () async {
      final release = Completer<void>();
      var blockedDecodeStarted = false;

      final controller = ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) async {
          blockedDecodeStarted = true;
          await release.future;
          return opaqueDecoded();
        },
        payloadEncoder: fakeJpegEncoder,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      final items = makeItems();
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(() => blockedDecodeStarted, 'the decode never started');

      // Anti-vacuity: prove the SAME wiring publishes a payload when no folder
      // switch intervenes, so a null below means "dropped", not "never worked".
      final control = ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) async => opaqueDecoded(),
        payloadEncoder: fakeJpegEncoder,
      );
      addTearDown(control.dispose);
      control.updateTargetSize(32, 32);
      await control.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => control.payloadFor(items[5].id) != null,
        'the control controller never published: this case cannot distinguish '
        'a dropped payload from a broken fixture',
      );

      controller.reset();
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // HONESTY NOTE (measured, not assumed): this case still passes with the
      // folder gate mutated OFF. A stale SUCCESS was ALREADY refused, by the
      // "left the window while the load was in flight" early-out -- `reset()`
      // empties `_navRetentionIds` and the sidebar's wanted set, so
      // `_retentionIds` (:320) no longer contains the id. So this is a
      // REGRESSION PIN for existing behaviour plus the gate's defence in
      // depth, NOT proof of the gate. The gate's own proof is TC-939: the
      // permanent-miss branch sits in the `else if (!outcome.deferred)` arm,
      // which no retention check guards, and that case DOES go red when the
      // gate is disabled.
      expect(
        controller.payloadFor(items[5].id),
        isNull,
        reason:
            'a payload decoded for the previous folder was published into the '
            'new one',
      );
      expect(controller.hasFailed(items[5].id), isFalse);
    },
  );

  test('TC-941 reset() bumps the decode pool generation exactly once', () {
    final original = ImagePreloadController.decodePoolGenerationSink;
    var bumps = 0;
    ImagePreloadController.decodePoolGenerationSink = () => bumps++;
    addTearDown(() {
      ImagePreloadController.decodePoolGenerationSink = original;
    });

    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageFailure('UNUSED', 'generation wiring only'),
    );
    addTearDown(controller.dispose);

    expect(bumps, isZero);
    controller.reset();
    expect(bumps, 1);
    controller.reset();
    expect(bumps, 2);
  });
}
