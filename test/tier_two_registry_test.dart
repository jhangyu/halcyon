import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';
import 'package:halcyon_flutter/services/photo_payload.dart';
import 'package:halcyon_flutter/services/raw_full_res_image.dart';
import 'package:halcyon_flutter/services/tier_two_registry.dart';

// A minimal valid 1x1 transparent PNG, so a real engine decode can be
// exercised without shipping a binary fixture file. Same bytes as
// test/image_preload_controller_test.dart:16-19.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// An ImageStreamCompleter that never emits an image and never errors --
/// used to deterministically simulate a decode that is PENDING forever,
/// without racing a real (near-instant) engine decode. When pre-inserted into
/// ImageCache under the exact key a real decode would use,
/// ImageCache.putIfAbsent returns this existing entry instead of starting a
/// new decode, so any code path that resolves that provider joins this
/// completer and never observes completion.
class _NeverCompletingImageStreamCompleter extends ImageStreamCompleter {}

/// A fresh encoded payload holding its OWN bytes object, so two payloads never
/// collide on the MemoryImage cache key (which is bytes identity + scale).
EncodedPayload _freshEncodedPayload() =>
    EncodedPayload(Uint8List.fromList(_tinyPngBytes));

/// A 1x1 fully transparent decoded image, for the full-res publish paths.
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

/// Publishes [payload] as an encoded tier-2 entry and waits for the decode
/// listener to fire. Returns the provider, which for MemoryImage IS the
/// ImageCache key.
Future<ImageProvider> _publishAndAwait(
  TierTwoRegistry registry,
  String id,
  EncodedPayload payload,
) async {
  final provider = fullSizeProviderFor(payload.bytes);
  final fired = Completer<void>();
  registry.publishEncoded(id, payload, provider, () {
    if (!fired.isCompleted) fired.complete();
  });
  await fired.future;
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Tests below use plain test(), never testWidgets(): the publish paths await
  // real engine futures (decodeImageFromPixels, MemoryImage decode), which
  // hang forever inside testWidgets' FakeAsync zone
  // (see test/image_preload_controller_test.dart:694-698).

  test('TC-231 isReady is false when nothing has been registered', () {
    final payload = _freshEncodedPayload();
    final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);

    expect(registry.isReady('IMG_00'), isFalse);
    expect(registry.keyIds, isEmpty);
    expect(registry.providerFor('IMG_00'), isNull);
    expect(registry.fullResProviderFor('IMG_00'), isNull);
  });

  test('TC-232 isReady is false while the entry is PENDING, not just missing', () async {
    final payload = _freshEncodedPayload();
    final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
    final provider = fullSizeProviderFor(payload.bytes);

    // Deterministically simulate "decode started, not yet finished":
    // pre-insert a never-completing entry under the SAME key the registry's
    // resolve will land on. MemoryImage is its own key, so `provider` IS it.
    final ic = PaintingBinding.instance.imageCache;
    ic.putIfAbsent(provider, () => _NeverCompletingImageStreamCompleter());
    addTearDown(() => ic.evict(provider));

    var notified = false;
    registry.publishEncoded('IMG_00', payload, provider, () => notified = true);
    // MemoryImage.obtainKey returns a SynchronousFuture, so the key/source
    // registration has already run by this line.
    await Future<void>.delayed(Duration.zero);

    expect(
      ic.containsKey(provider),
      isTrue,
      reason: 'sanity check: the PENDING entry is present in ImageCache -- '
          'this is the fact BLOCKER 3 showed containsKey alone cannot '
          'distinguish from "decode finished"',
    );
    expect(registry.keyIds, contains('IMG_00'));
    expect(notified, isFalse);
    expect(
      registry.isReady('IMG_00'),
      isFalse,
      reason: 'the decode never completed -- isReady must not report true '
          'just because ImageCache.containsKey is true for a pending entry',
    );
  });

  test('TC-233 isReady is true once the decode listener has fired', () async {
    final payload = _freshEncodedPayload();
    final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
    addTearDown(registry.clear);

    final provider = await _publishAndAwait(registry, 'IMG_00', payload);

    expect(PaintingBinding.instance.imageCache.containsKey(provider), isTrue);
    expect(registry.keyIds, {'IMG_00'});
    expect(registry.providerFor('IMG_00'), same(provider));
    expect(
      registry.isReady('IMG_00'),
      isTrue,
      reason: 'all four terms hold: listener fired, key registered, source is '
          'the current payload, entry resident',
    );
  });

  test('TC-234 isReady goes false when the payload object is replaced', () async {
    final original = _freshEncodedPayload();
    // The BLOCKER-1 scenario as a one-line closure swap. Reaching this through
    // the controller needs a 10-step navigation excursion plus two 350ms
    // debounce sleeps (image_preload_controller_test.dart:526-624).
    SourcePayload current = original;
    final registry = TierTwoRegistry(currentPayloadFor: (id) => current);
    addTearDown(registry.clear);

    await _publishAndAwait(registry, 'IMG_00', original);
    expect(registry.isReady('IMG_00'), isTrue);

    // The item left the retention window and came back with a NEW payload
    // object; the id-keyed bookkeeping still describes the OLD one.
    final replacement = _freshEncodedPayload();
    expect(identical(original, replacement), isFalse);
    current = replacement;

    expect(
      registry.isReady('IMG_00'),
      isFalse,
      reason: 'the registered entry was decoded for a payload that is no '
          'longer current -- stale readiness (round-2 BLOCKER 1)',
    );
    expect(
      registry.fullResProviderFor('IMG_00'),
      isNull,
      reason: 'every read gated on readiness must go null together',
    );
  });

  test('TC-235 isReady goes false when the ImageCache entry is evicted underneath', () async {
    final payload = _freshEncodedPayload();
    final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
    addTearDown(registry.clear);

    final provider = await _publishAndAwait(registry, 'IMG_00', payload);
    expect(registry.isReady('IMG_00'), isTrue);

    // Someone else's cache pressure (or a tier-1 sweep) dropped the entry.
    // The bookkeeping is untouched -- only residency changed.
    PaintingBinding.instance.imageCache.evict(provider);

    expect(registry.keyIds, contains('IMG_00'));
    expect(
      registry.isReady('IMG_00'),
      isFalse,
      reason: 'readiness is re-derived at read time against ImageCache '
          'residency, not cached in the ready flag',
    );
  });

  test('TC-236 hasFullResEntryFor is true BEFORE the ready flag fires (AC-M5-4)', () async {
    final payload = PixelPayload(rgba: Uint8List(4), width: 1, height: 1);
    final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
    addTearDown(registry.clear);

    // RawFullResImage equality is identical(payloadIdentity) + width + height,
    // so this key is == the one publishFullRes is about to build. Pre-inserting
    // a never-completing entry under it makes the publish resolve join a
    // pending entry, so its listener never fires.
    final pendingKey = RawFullResImage(
      payloadIdentity: payload,
      width: 1,
      height: 1,
      image: await _tinyImage(),
    );
    final ic = PaintingBinding.instance.imageCache;
    ic.putIfAbsent(pendingKey, () => _NeverCompletingImageStreamCompleter());
    addTearDown(() => ic.evict(pendingKey));

    var notified = false;
    registry.publishFullRes(
      'IMG_00',
      payload,
      await _tinyImage(),
      () => notified = true,
    );

    expect(notified, isFalse);
    expect(
      registry.isReady('IMG_00'),
      isFalse,
      reason: 'the full-res decode has not been delivered yet',
    );
    expect(
      registry.hasFullResEntryFor('IMG_00', payload),
      isTrue,
      reason: 'registration is synchronous and this is the question that '
          'decides whether to spend an FFI decode -- asking isReady here '
          'would buy a SECOND decode for an upgrade already in hand, which '
          'is exactly what AC-M5-4 forbids',
    );
    expect(
      registry.hasFullResEntryFor('IMG_00', _freshEncodedPayload()),
      isFalse,
      reason: 'the entry belongs to one payload object, not to the id',
    );
  });

  test('TC-237 the full-res failure memo is per payload object, not per id', () {
    final original = _freshEncodedPayload();
    SourcePayload current = original;
    final registry = TierTwoRegistry(currentPayloadFor: (id) => current);

    expect(registry.hasFullResFailure('IMG_00', original), isFalse);

    registry.markFullResFailure('IMG_00', original);
    expect(
      registry.hasFullResFailure('IMG_00', original),
      isTrue,
      reason: 'a failed upgrade must not be re-bought on every 250ms settle',
    );

    // The item left the retention window and came back: NEW payload object,
    // so the memo must not apply and the upgrade may be tried once more
    // (design §2.5 -- a failed upgrade is not a permanent miss).
    final replacement = _freshEncodedPayload();
    current = replacement;
    expect(registry.hasFullResFailure('IMG_00', replacement), isFalse);

    // ...and it is not a permanent miss for the id either.
    expect(registry.hasFullResFailure('IMG_01', original), isFalse);
  });

  test('TC-238 evict drops one id and clear drops every id', () async {
    final payloadA = _freshEncodedPayload();
    final payloadB = _freshEncodedPayload();
    final byId = {'IMG_00': payloadA, 'IMG_01': payloadB};
    final registry = TierTwoRegistry(currentPayloadFor: (id) => byId[id]);
    addTearDown(registry.clear);

    final providerA = await _publishAndAwait(registry, 'IMG_00', payloadA);
    final providerB = await _publishAndAwait(registry, 'IMG_01', payloadB);
    expect(registry.keyIds, {'IMG_00', 'IMG_01'});

    final ic = PaintingBinding.instance.imageCache;
    registry.evict('IMG_00');

    expect(registry.keyIds, {'IMG_01'});
    expect(registry.providerFor('IMG_00'), isNull);
    expect(registry.isReady('IMG_00'), isFalse);
    expect(
      ic.containsKey(providerA),
      isFalse,
      reason: 'evict must drop the ImageCache entry as well as the bookkeeping',
    );
    expect(
      registry.isReady('IMG_01'),
      isTrue,
      reason: 'evict is per id -- it must not disturb its neighbours',
    );

    registry.clear();

    expect(registry.keyIds, isEmpty);
    expect(registry.isReady('IMG_01'), isFalse);
    expect(ic.containsKey(providerB), isFalse);
  });
}
