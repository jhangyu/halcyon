// TC-916 / TC-917 / TC-918 / TC-923 / TC-924.
//
// Contract deliverable W2 (docs/logs/2026-09-04/remediation-round-contract.md
// / residual-jank-diagnosis.md #3 and #7):
//   - a repeat `publishEncoded` for the SAME (id, payload-object) is dropped
//     as a redundant re-publish (11.1 publishes/id observed, target ~2);
//   - a NEW payload object (content-version) for the same id still lands --
//     the tier1 -> full-res upgrade case must not break;
//   - both TierTwoScheduler call sites that used to call
//     `TierTwoRegistry.publishEncoded` DIRECTLY now route through the pacer
//     (148 unpaced publishes observed).

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

import '../../support/preload_fixtures.dart';

/// An ImageStreamCompleter that never emits an image and never errors --
/// deterministically simulates "registration landed, decode still pending"
/// without racing a real (near-instant) engine decode. Same trick as
/// tier_two_registry_test.dart's TC-232, duplicated here rather than shared
/// so this file's ownership stays self-contained.
class _NeverCompletingImageStreamCompleter extends ImageStreamCompleter {}

/// Records every submission; publishes exempt ones immediately and defers
/// everything else until [drain] -- same shape as the fake pacer in
/// tier_two_publish_pacing_test.dart (TC-907/908), duplicated here rather
/// than shared so this file's ownership stays self-contained.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'TC-916 a second publishEncoded call for the SAME (id, payload object) '
    'is dropped instead of re-publishing',
    () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final firstProvider = fullSizeProviderFor(payload.bytes);
      var firstNotifications = 0;
      registry.publishEncoded(
        'IMG_00',
        payload,
        firstProvider,
        () => firstNotifications++,
      );
      await until(() => firstNotifications == 1,
          reason: 'the first publish lands');
      expect(registry.providerFor('IMG_00'), same(firstProvider));

      // Same id, same payload OBJECT, a fresh (would-be) provider -- this
      // must be dropped: no re-registration, no second notification.
      final secondProvider = fullSizeProviderFor(payload.bytes);
      var secondNotifications = 0;
      registry.publishEncoded(
        'IMG_00',
        payload,
        secondProvider,
        () => secondNotifications++,
      );
      // No completion signal to await for a dropped duplicate -- give the
      // event loop a few turns, then assert it never fired.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        secondNotifications,
        0,
        reason: 'the duplicate publish must not resolve a second listener',
      );
      expect(
        registry.providerFor('IMG_00'),
        same(firstProvider),
        reason: 'the registry entry must still be the FIRST publish\'s '
            'provider -- the duplicate must not overwrite it',
      );
    },
  );

  test(
    'TC-923 a same-payload republish LANDS once the earlier entry has been '
    'evicted from ImageCache underneath (round-2 review BLOCKER-1: eviction '
    'recovery must not be permanently blocked by the dedupe guard)',
    () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final firstProvider = fullSizeProviderFor(payload.bytes);
      registry.publishEncoded('IMG_00', payload, firstProvider, () {});
      await until(() => registry.isReady('IMG_00'),
          reason: 'the first publish lands');

      // Simulate LRU eviction pressure: ImageCache drops the entry WITHOUT
      // telling the registry. _sources still holds the same payload object,
      // but isReady must go false (residency check).
      PaintingBinding.instance.imageCache.evict(firstProvider);
      expect(registry.isReady('IMG_00'), isFalse,
          reason: 'sanity check: the entry is no longer resident');

      // The window sweep's recovery path resubmits the SAME payload object
      // to re-populate the cache. This must NOT be dropped as a duplicate --
      // the earlier entry is gone, not still resident.
      final secondProvider = fullSizeProviderFor(payload.bytes);
      var recovered = false;
      registry.publishEncoded(
        'IMG_00',
        payload,
        secondProvider,
        () => recovered = true,
      );
      await until(() => recovered,
          reason: 'the recovery republish for the SAME payload object must '
              'land once the earlier entry is no longer resident');

      expect(registry.isReady('IMG_00'), isTrue);
      expect(registry.providerFor('IMG_00'), same(secondProvider));
    },
  );

  test(
    'TC-924 a same-payload resubmit DURING the pending window (registered, '
    'decode not yet complete, ImageCache entry still resident) is dropped '
    '-- round-2 review re-review S1: residency must be checked with '
    'ImageCache.containsKey, not isReady, or a mid-decode resubmit slips '
    'through',
    () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final firstProvider = fullSizeProviderFor(payload.bytes);
      // Deterministically simulate "decode started, not yet finished" (same
      // trick as tier_two_registry_test.dart TC-232): pre-insert a
      // never-completing entry under the SAME key the registry's resolve
      // will land on, so the listener never fires but the registration
      // (obtainKey().then(...)) still completes synchronously.
      final ic = PaintingBinding.instance.imageCache;
      ic.putIfAbsent(firstProvider, () => _NeverCompletingImageStreamCompleter());
      addTearDown(() => ic.evict(firstProvider));

      var firstNotified = false;
      registry.publishEncoded(
        'IMG_00',
        payload,
        firstProvider,
        () => firstNotified = true,
      );
      // MemoryImage.obtainKey returns a SynchronousFuture, so registration
      // has already run by the next microtask turn.
      await Future<void>.delayed(Duration.zero);

      expect(registry.providerFor('IMG_00'), same(firstProvider),
          reason: 'sanity check: the first publish registered');
      expect(firstNotified, isFalse,
          reason: 'sanity check: the decode never completed -- still pending');
      expect(registry.isReady('IMG_00'), isFalse,
          reason: 'sanity check: isReady is false during the pending window '
              '(same fact BLOCKER 3 documents)');
      expect(ic.containsKey(firstProvider), isTrue,
          reason: 'sanity check: the entry IS still resident -- pending, not '
              'evicted');

      // Resubmitting the SAME payload object while still pending must be
      // dropped: the entry is still resident (containsKey true), even
      // though isReady is false. Using isReady here (instead of
      // containsKey) would have let this through.
      final secondProvider = fullSizeProviderFor(payload.bytes);
      var secondNotified = false;
      registry.publishEncoded(
        'IMG_00',
        payload,
        secondProvider,
        () => secondNotified = true,
      );
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(secondNotified, isFalse,
          reason: 'the mid-pending resubmit must be dropped as a duplicate');
      expect(registry.providerFor('IMG_00'), same(firstProvider),
          reason: 'the registry entry must still be the FIRST publish\'s '
              'provider -- the duplicate must not overwrite it');
    },
  );

  test(
    'TC-917 a NEW content-version (different payload object) for the same '
    'id still lands even right after the first publish',
    () async {
      SourcePayload current = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => current);
      addTearDown(registry.clear);

      final firstPayload = current as EncodedPayload;
      final firstProvider = fullSizeProviderFor(firstPayload.bytes);
      registry.publishEncoded('IMG_00', firstPayload, firstProvider, () {});
      await until(() => registry.isReady('IMG_00'),
          reason: 'the first publish lands');

      // tier1 -> full-res upgrade (or a re-encode landing): a genuinely NEW
      // payload object for the same id must always be published, never
      // treated as a duplicate.
      final secondPayload = freshEncodedPayload();
      current = secondPayload;
      final secondProvider = fullSizeProviderFor(secondPayload.bytes);
      var secondNotified = false;
      registry.publishEncoded(
        'IMG_00',
        secondPayload,
        secondProvider,
        () => secondNotified = true,
      );
      await until(() => secondNotified,
          reason: 'a new content-version must not be dropped as a duplicate');

      expect(registry.providerFor('IMG_00'), same(secondProvider));
      expect(registry.isReady('IMG_00'), isTrue);
    },
  );

  test(
    'TC-918 publishEncoded now goes through the paced path: a non-selected '
    'item\'s encoded publish does not land until the pacer drains',
    () async {
      final payloads = <String, SourcePayload>{
        'a0': freshEncodedPayload(),
        'a1': freshEncodedPayload(),
      };
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
      addTearDown(registry.clear);
      final pacer = _FakePacer();

      final scheduler = TierTwoScheduler(
        registry: registry,
        lane: DecodeLane(width: 2),
        currentPayloadFor: (id) => payloads[id],
        fullSizeProviderFor: (p) =>
            fullSizeProviderFor((p as EncodedPayload).bytes),
        ensurePayload:
            (item, {required int distance, required VoidCallback? notifyLoaded, bool onSerialLane = false}) async {},
        dngDecoder: () => null,
        exifOrientationFor: (id) => 1,
        navigationDebounce: Duration.zero,
        publishPacer: pacer.submit,
      );
      addTearDown(scheduler.cancelDebounce);

      // Selection is index 1 ('a1'); 'a0' is a neighbour at distance -1, both
      // already have an EncodedPayload so _decodeWindow's catch-up loop
      // publishes both without any FFI decode involved.
      final items = [
        PhotoItem(id: 'a0', files: [File('/tmp/a0.jpg')]),
        PhotoItem(id: 'a1', files: [File('/tmp/a1.jpg')]),
      ];
      scheduler.updateWindow(items, 1);
      scheduler.schedule(items, 1, () {});

      await until(
        () =>
            pacer.submissions.any((s) => s.id == 'a0') &&
            pacer.submissions.any((s) => s.id == 'a1'),
        reason: 'both encoded publishes reach the pacer',
      );

      final a0Submission = pacer.submissions.firstWhere((s) => s.id == 'a0');
      final a1Submission = pacer.submissions.firstWhere((s) => s.id == 'a1');
      expect(a0Submission.exempt, isFalse,
          reason: 'a0 is not the selected item -- publishEncoded must be '
              'PACED for it, not sent straight to the registry');
      expect(a1Submission.exempt, isTrue,
          reason: 'a1 (distance 0) is the selected item, exempt from pacing');

      await until(() => registry.isReady('a1'),
          reason: 'the selected item\'s publish is exempt and lands immediately');
      expect(
        registry.isReady('a0'),
        isFalse,
        reason: 'the non-selected encoded publish must not land '
            'synchronously -- it is queued in the (fake) pacer',
      );

      pacer.drain();
      await until(() => registry.isReady('a0'),
          reason: 'draining the pacer publishes the queued encoded entry');
    },
  );
}
