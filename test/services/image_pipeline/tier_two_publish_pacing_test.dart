// TC-907 / TC-908 (provisional -- numbers to be assigned against the SOP
// register at round end, per the contract's registration rule).
//
// Contract deliverable 2 (docs/logs/2026-09-04/pacer-followup-contract.md):
// TierTwoRegistry.publishFullRes must no longer be reachable from
// TierTwoScheduler without going through a pacing seam. These tests drive
// TierTwoScheduler with a fake PublishPacer that records every submission
// and defers non-exempt ones, asserting:
//   (a) a non-selected item's full-res publish does NOT land synchronously
//       on decode completion (exempt: false, and the registry has no entry
//       until the fake pacer is drained);
//   (b) the selected item's full-res publish is exempt (never queued), so it
//       is never starved by the pacer.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

/// Records every [TierTwoScheduler] publish submission and defers everything
/// non-exempt until [drain] is called -- standing in for `PublicationPacer`
/// without depending on its concrete type (that class is out of this
/// worker's file ownership this round; only the [PublishPacer] SHAPE is
/// shared).
class _FakePacer {
  final List<({String id, bool exempt})> submissions = [];
  final List<
      ({
        bool Function() stillValid,
        void Function() publish,
        void Function()? discard,
      })> _queued = [];

  void submit({
    required String id,
    required int rank,
    required bool exempt,
    required bool Function() stillValid,
    required void Function() publish,
    void Function()? discard,
  }) {
    submissions.add((id: id, exempt: exempt));
    if (exempt) {
      if (stillValid()) {
        publish();
      } else {
        discard?.call();
      }
      return;
    }
    _queued.add((stillValid: stillValid, publish: publish, discard: discard));
  }

  /// Publishes every queued (non-exempt) entry, mirroring `PublicationPacer`
  /// draining a frame.
  void drain() {
    for (final entry in _queued) {
      if (entry.stillValid()) {
        entry.publish();
      } else {
        entry.discard?.call();
      }
    }
    _queued.clear();
  }
}

PixelPayload _pixelPayload() =>
    PixelPayload(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);

/// Pumps the microtask/timer queue until [condition] holds or [maxIters] is
/// reached, instead of a fixed iteration count -- a fixed count of
/// `Future.delayed(Duration.zero)` turns proved flaky when this suite runs
/// alongside its siblings (heavier event-loop load needs more turns for the
/// SAME async chain to settle; observed in this round's own CI-style
/// multi-file run, see docs/logs/2026-09-04/r1-pacer2-verify.txt).
Future<void> _pumpUntil(bool Function() condition, {int maxIters = 200}) async {
  for (var i = 0; i < maxIters && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'TC-907 a non-selected full-res upgrade does not land synchronously; '
    'draining the pacer publishes it',
    () async {
      final payloads = <String, SourcePayload>{
        'a0': _pixelPayload(),
        'a1': _pixelPayload(),
      };
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
      addTearDown(registry.clear);
      final pacer = _FakePacer();

      final decodeGate = <String, Completer<void>>{};
      final scheduler = TierTwoScheduler(
        registry: registry,
        lane: DecodeLane(width: 2),
        currentPayloadFor: (id) => payloads[id],
        fullSizeProviderFor: (p) => throw StateError('not exercised here'),
        ensurePayload:
            (item, {required int distance, required VoidCallback? notifyLoaded, bool onSerialLane = false}) async {},
        dngDecoder: (() {
          Future<DecodedRgba> decode(String path) async {
            final id = path.split('/').last.split('.').first;
            await (decodeGate[id] ??= Completer<void>()).future;
            return DecodedRgba(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);
          }

          return () => decode;
        })(),
        exifOrientationFor: (id) => 1,
        navigationDebounce: Duration.zero,
        publishPacer: pacer.submit,
      );
      addTearDown(scheduler.cancelDebounce);

      // Selection is index 1 ('a1'); 'a0' is a neighbour at distance -1.
      final items = [
        PhotoItem(id: 'a0', files: [File('/tmp/a0.dng')]),
        PhotoItem(id: 'a1', files: [File('/tmp/a1.dng')]),
      ];
      scheduler.updateWindow(items, 1);
      scheduler.schedule(items, 1, () {});

      // Both decodes must be in flight (lane width 2) before releasing them.
      await _pumpUntil(
        () => decodeGate.containsKey('a0') && decodeGate.containsKey('a1'),
      );
      decodeGate['a0']!.complete();
      decodeGate['a1']!.complete();
      await _pumpUntil(
        () =>
            pacer.submissions.any((s) => s.id == 'a0') &&
            pacer.submissions.any((s) => s.id == 'a1'),
      );

      final a0Submission =
          pacer.submissions.firstWhere((s) => s.id == 'a0');
      final a1Submission =
          pacer.submissions.firstWhere((s) => s.id == 'a1');
      expect(a0Submission.exempt, isFalse,
          reason: 'a0 is not the selected item');
      expect(a1Submission.exempt, isTrue,
          reason: 'a1 (distance 0) is the selected item');

      // The non-selected publish must NOT have landed synchronously: the
      // registry has no ready entry for a0 until the pacer is drained.
      expect(registry.isReady('a0'), isFalse);
      // The selected item's publish is exempt, so it lands immediately and
      // is never starved.
      expect(registry.isReady('a1'), isTrue);

      pacer.drain();
      expect(registry.isReady('a0'), isTrue,
          reason: 'draining the pacer publishes the queued entry');
    },
  );

  test(
    'TC-908 a paced publish re-checks staleness at drain time: a payload '
    'replaced before drain disposes the image instead of caching it',
    () async {
      final payload = _pixelPayload();
      final payloads = <String, SourcePayload>{'a0': payload};
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
      addTearDown(registry.clear);
      final pacer = _FakePacer();

      final decodeGate = Completer<void>();
      var decoderCalls = 0;
      final scheduler = TierTwoScheduler(
        registry: registry,
        lane: DecodeLane(width: 1),
        currentPayloadFor: (id) => payloads[id],
        fullSizeProviderFor: (p) => throw StateError('not exercised here'),
        ensurePayload:
            (item, {required int distance, required VoidCallback? notifyLoaded, bool onSerialLane = false}) async {},
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
        publishPacer: pacer.submit,
      );
      addTearDown(scheduler.cancelDebounce);

      // Selection at index 1, 'a0' at distance -1: non-exempt, gets queued.
      final items = [
        PhotoItem(id: 'a0', files: [File('/tmp/a0.dng')]),
        PhotoItem(id: 'x', files: [File('/tmp/x.dng')]),
      ];
      scheduler.updateWindow(items, 1);
      scheduler.schedule(items, 1, () {});
      // Let the debounce fire and the upgrade reach its held decode.
      await _pumpUntil(() => decoderCalls > 0);
      decodeGate.complete();
      await _pumpUntil(() => pacer.submissions.any((s) => s.id == 'a0' && !s.exempt));

      expect(pacer.submissions.any((s) => s.id == 'a0' && !s.exempt), isTrue);
      expect(registry.isReady('a0'), isFalse, reason: 'still queued');

      // The payload is replaced BEFORE the pacer drains.
      payloads['a0'] = _pixelPayload();

      pacer.drain();
      expect(registry.isReady('a0'), isFalse,
          reason: 'the queued image was for the OLD payload object');
    },
  );
}
