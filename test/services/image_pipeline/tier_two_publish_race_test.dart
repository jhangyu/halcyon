// TC-381a / TC-381b (provisional numbers -- re-verify against the SOP register
// at merge). Defect B from docs/logs/2026-08-30/lane-race-arch-verdict.md §1.B:
// every caller checks `hasFullResEntryFor` BEFORE its decode await, and the
// post-await re-check validates window + payload identity but NOT entry
// existence. Whichever publisher lands second overwrites `_keys[id]`, and the
// displaced RawFullResImage's full-resolution ui.Image is never disposed.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

/// A 1x1 opaque decoded image -- the smallest thing that is a real ui.Image,
/// so `debugDisposed` is a real engine fact and not a test double's flag.
Future<ui.Image> _tinyImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List(4),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

PixelPayload _pixelPayload() =>
    PixelPayload(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);

void main() {
  // Plain test(), never testWidgets(): these paths await real engine futures
  // (decodeImageFromPixels), which hang forever inside a FakeAsync zone.
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'TC-381a publishFullRes is first-writer-wins: the loser is disposed, not '
    'leaked, and the registered provider never changes',
    () async {
      final payload = _pixelPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final winner = await _tinyImage();
      final loser = await _tinyImage();

      var winnerNotifies = 0;
      var loserNotifies = 0;

      registry.publishFullRes('a0', payload, winner, () => winnerNotifies++);
      final firstProvider = registry.providerFor('a0');
      expect(firstProvider, isNotNull);

      // The second publisher for the SAME id and the SAME payload object --
      // exactly what the piggyback/upgrade race produces.
      registry.publishFullRes('a0', payload, loser, () => loserNotifies++);

      expect(
        identical(registry.providerFor('a0'), firstProvider),
        isTrue,
        reason: 'first writer wins: its live resolve/listener chain stands',
      );
      expect(
        loser.debugDisposed,
        isTrue,
        reason:
            'the surplus decode product must be released here; nothing else '
            'holds a reference to it, so otherwise it leaks ~91MiB',
      );
      expect(
        winner.debugDisposed,
        isFalse,
        reason: 'the winner is owned by the ImageCache entry and stays alive',
      );
      expect(
        loserNotifies,
        0,
        reason: 'the first writer owns the notification for this entry',
      );

      // Let the winner's listener fire, so teardown is not racing a pending
      // decode. (The value is not asserted; TC-231.. cover readiness.)
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(winnerNotifies, greaterThanOrEqualTo(0));
    },
  );

  test(
    'TC-381b a piggyback publish landing during an upgrade decode is not '
    'displaced by that upgrade (decode lane width 2)',
    () async {
      final payload = _pixelPayload();
      final payloads = <String, SourcePayload>{'a0': payload};
      final registry = TierTwoRegistry(
        currentPayloadFor: (id) => payloads[id],
      );
      addTearDown(registry.clear);

      // The upgrade's FFI decode, held open so the piggyback can land inside
      // the gap between the upgrade's pre-await existence check and its
      // publish -- the exact window the defect lives in.
      final decodeGate = Completer<void>();
      var decoderCalls = 0;

      final scheduler = TierTwoScheduler(
        registry: registry,
        lane: DecodeLane(width: 2),
        currentPayloadFor: (id) => payloads[id],
        fullSizeProviderFor: (p) => throw StateError('not exercised here'),
        ensurePayload:
            (
              item, {
              required int distance,
              required VoidCallback? notifyLoaded,
              bool onSerialLane = false,
            }) async {
              // The payload is already retained; this is the catch-up case.
            },
        dngDecoder: (() {
          Future<DecodedRgba> decode(String path) async {
            decoderCalls++;
            await decodeGate.future;
            return DecodedRgba(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);
          }

          return () => decode;
        })(),
        exifOrientationFor: (id) => 1,
        navigationDebounce: Duration.zero,
      );
      addTearDown(scheduler.cancelDebounce);

      final items = List.generate(
        4,
        (i) => PhotoItem(id: 'a$i', files: [File('/tmp/a$i.dng')]),
      );

      scheduler.updateWindow(items, 0);
      scheduler.schedule(items, 0, () {});

      // Let the debounce fire and the upgrade reach its held decode.
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(decoderCalls, 1, reason: 'the catch-up upgrade decode started');

      // The piggyback publisher lands WHILE the upgrade decode is held.
      await scheduler.publishPiggybackFullRes(
        'a0',
        payload,
        (rgba: Uint8List(1 * 1 * 4), width: 1, height: 1),
        () {},
      );
      final piggybackProvider = registry.providerFor('a0');
      expect(piggybackProvider, isNotNull);

      // Release the upgrade: its post-await re-check passes (same window,
      // same payload object), so it reaches publishFullRes.
      decodeGate.complete();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        identical(registry.providerFor('a0'), piggybackProvider),
        isTrue,
        reason:
            'the late upgrade must not displace the live entry; the displaced '
            'RawFullResImage would hold a full-resolution ui.Image nothing '
            'can ever evict or dispose',
      );
      expect(registry.keyIds, {'a0'});
    },
  );
}
