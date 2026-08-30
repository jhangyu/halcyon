import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'photo_payload.dart';
import 'raw_full_res_image.dart';

/// Owns the TIER-2 (full size) ImageCache bookkeeping that used to live inline
/// in [ImagePreloadController]: which id currently holds a tier-2 entry, which
/// payload OBJECT that entry was decoded for, whether its decode has actually
/// finished, and whether a full-resolution upgrade already failed for that same
/// payload object.
///
/// It owns state and nothing else. Scheduling -- the +/-2 window, the 250ms
/// navigation debounce, the sequential decode queue -- stays in the controller,
/// because those need the payload cache, the scheduler and the photo source,
/// while everything here is answerable from four containers and one lookup.
///
/// These maps are id-keyed, but the ImageCache entry they describe is keyed by
/// PAYLOAD OBJECT IDENTITY. When an item leaves the retention window and later
/// returns, it gets a NEW payload, so a stale id-keyed "ready" flag would point
/// at an ImageCache entry for a payload that is no longer current -- readiness
/// must be re-derived at read time against the CURRENT payload (round-2 review
/// BLOCKER 1). That re-derivation is [isReady], and after this extraction it is
/// the ONLY place the four terms of the conjunction exist.
class TierTwoRegistry {
  TierTwoRegistry({required SourcePayload? Function(String id) currentPayloadFor})
    : _currentPayloadFor = currentPayloadFor;

  /// The controller's CURRENT payload for an id -- bound to
  /// `PhotoPayloadCache.peek`. Injected rather than holding the cache itself,
  /// so retention stays single-owned and a unit test can drive the BLOCKER-1
  /// stale-payload scenario by swapping one closure.
  final SourcePayload? Function(String id) _currentPayloadFor;

  /// id -> the ImageCache key, which for every tier-2 kind IS the provider
  /// itself (`MemoryImage` is its own key; `RawFullResImage.obtainKey` returns
  /// `this`).
  final Map<String, Object> _keys = {};

  /// id -> the payload object the entry under [_keys] was decoded for.
  final Map<String, SourcePayload> _sources = {};

  /// ids whose decode listener has actually fired.
  final Set<String> _readyIds = {};

  /// Full-resolution upgrade failures, remembered PER PAYLOAD OBJECT (design
  /// §2.5). A RAW whose full-res decode failed keeps its tier-1 display and is
  /// NOT a permanent miss -- that set means "no payload could be produced at
  /// all", and writing to it here would turn a failed upgrade into an
  /// "unreadable" error screen for an item that is on screen and fine.
  ///
  /// Keyed by id but compared with [identical] against the CURRENT payload, so
  /// the memo dies naturally when the payload is replaced and the upgrade may
  /// be tried once more. Without it, every 250ms settle would re-run a
  /// 61-406ms FFI decode that just failed.
  final Map<String, SourcePayload> _fullResFailures = {};

  ImageCache get _imageCache => PaintingBinding.instance.imageCache;

  /// Whether the full-size (tier-2) decode for [id] has COMPLETED and the
  /// resulting ImageCache entry is still resident **for the item's current
  /// payload**. A conjunction of two independent facts, both required
  /// (round-2 review BLOCKER 1 and BLOCKER 3 each came from having only one):
  ///   1. `_readyIds.contains(id)` -- the decode listener's onImage callback
  ///      fired, i.e. the decode actually finished. Without this,
  ///      `ImageCache.containsKey` returns true for a PENDING entry too
  ///      (SDK image_cache.dart: `_pendingImages[key] != null ||
  ///      _cache[key] != null`), and `MemoryImage.obtainKey` resolves
  ///      synchronously right after `resolve()` inserts the pending entry --
  ///      so a containsKey-only check flips true the instant a ~124ms
  ///      full-frame decode STARTS, not when it lands (BLOCKER 3).
  ///   2. `identical(decodedFor, current)` + `containsKey(key)` -- the finished
  ///      entry is still the one for the CURRENT payload and is still resident,
  ///      not stale bookkeeping for a payload since replaced (BLOCKER 1).
  ///
  /// Both kinds of payload go through this same conjunction. The pixel kind
  /// used to get its own early return, which meant loosening exactly the terms
  /// that keep those two blockers dead (design §4, invariant I3).
  bool isReady(String id) {
    if (!_readyIds.contains(id)) return false;
    final key = _keys[id];
    if (key == null) return false;
    final decodedFor = _sources[id];
    final current = _currentPayloadFor(id);
    if (decodedFor == null || !identical(decodedFor, current)) return false;
    return _imageCache.containsKey(key);
  }

  /// The FULL-RESOLUTION tier-2 provider for a pixel-backed item, or null when
  /// there is no resident full-resolution entry for the item's current payload.
  ///
  /// This must NOT be rebuilt at the display site: [RawFullResImage] is
  /// one-shot (it carries the decoded image exactly once), so the object handed
  /// out here is the very object registered as the ImageCache key. Resolving it
  /// while [isReady] is true is a plain cache hit -- `loadImage` is never
  /// reached, so the one-shot nature is never exercised on the display path
  /// (design §2.3).
  ImageProvider? fullResProviderFor(String id) {
    if (!isReady(id)) return null;
    final key = _keys[id];
    return key is RawFullResImage ? key : null;
  }

  /// The tier-2 provider currently registered for [id] -- a [RawFullResImage]
  /// for a pixel-backed item, the encoded path's own provider otherwise -- or
  /// null when the item has no tier-2 entry.
  ///
  /// Every tier-2 key here IS its own provider, so this is a read of the
  /// existing bookkeeping and not a second registry.
  ImageProvider<Object>? providerFor(String id) {
    final key = _keys[id];
    return key is ImageProvider<Object> ? key : null;
  }

  /// The ids that currently hold a tier-2 ImageCache entry, both payload kinds.
  /// The dual-window property under test is exactly "this set == the +/-2 band"
  /// (AC-M5-2). Returns a copy: no internal container leaves this class.
  Set<String> get keyIds => _keys.keys.toSet();

  /// True when [id] already has a FULL-RESOLUTION tier-2 entry registered for
  /// exactly this payload object. Deliberately not [isReady]: this is checked
  /// to decide whether to spend an FFI decode, and the entry may still be a few
  /// microseconds away from its listener firing (the ready flag is set by the
  /// stream listener; the registration in [publishFullRes] is synchronous).
  /// Asking the ready flag here would buy a second decode for an upgrade
  /// already in hand, which is exactly what AC-M5-4's "exactly ONE decoder
  /// call" forbids.
  bool hasFullResEntryFor(String id, SourcePayload payload) =>
      _keys[id] is RawFullResImage && identical(_sources[id], payload);

  /// True when a full-resolution upgrade already failed for THIS payload
  /// object. Compared with [identical], so the memo dies with the payload.
  bool hasFullResFailure(String id, SourcePayload payload) =>
      identical(_fullResFailures[id], payload);

  /// Registers [provider] (already built by the controller's
  /// `_fullSizeProviderForPayload`, so the payload -> provider mapping stays
  /// in one place) as [id]'s tier-2 entry.
  ///
  /// ORDERING IS BEHAVIOUR: resolve + addListener happen FIRST, and the key and
  /// source are recorded only when `obtainKey` completes. Making the
  /// registration synchronous would let [isReady] flip earlier than it does
  /// today -- the exact direction BLOCKER 3 guards.
  void publishEncoded(
    String id,
    SourcePayload payload,
    ImageProvider provider,
    VoidCallback notifyLoaded,
  ) {
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener((image, synchronousCall) {
      stream.removeListener(listener);
      _readyIds.add(id);
      notifyLoaded();
    }, onError: (error, stackTrace) => stream.removeListener(listener));
    stream.addListener(listener);
    provider.obtainKey(const ImageConfiguration()).then((key) {
      _keys[id] = key;
      _sources[id] = payload;
    });
  }

  /// Hands ownership of [image] to the ImageCache and keeps NO reference to it
  /// (invariant I5 stays dissolved -- nothing here owns a ~50MB handle).
  /// Registration is synchronous and happens BEFORE the resolve, so a
  /// concurrent decision to upgrade sees the entry immediately. This is the
  /// OPPOSITE ordering to [publishEncoded], and both are deliberate.
  void publishFullRes(
    String id,
    SourcePayload payload,
    ui.Image image,
    VoidCallback notifyLoaded,
  ) {
    // FIRST WRITER WINS (verdict 2026-08-30 fix B). Every caller checks
    // `hasFullResEntryFor` BEFORE its decode await, and the post-await
    // re-checks validate window membership and payload identity but not entry
    // EXISTENCE -- so a piggyback publish landing during an upgrade decode is
    // invisible to that upgrade. The loser used to overwrite `_keys[id]`,
    // orphaning a full-resolution ui.Image that nothing could evict or
    // dispose. This guard is synchronous and sits in the single funnel every
    // publisher passes through, so it also covers callers that do not exist
    // yet.
    if (hasFullResEntryFor(id, payload)) {
      image.dispose();
      // No notifyLoaded: the winning entry's own listener owns that.
      return;
    }
    // Any entry still here is for a DIFFERENT (replaced) payload. Evicting it
    // before the overwrite closes the same orphan leak on the stale-payload
    // path.
    evict(id);
    final provider = RawFullResImage(
      payloadIdentity: payload,
      width: image.width,
      height: image.height,
      image: image,
    );
    // The provider IS its own key (obtainKey returns `this`), which is what
    // lets the existing tier-2 bookkeeping evict it and the view resolve the
    // very same object as a cache hit. No second eviction mechanism (§2.4).
    _keys[id] = provider;
    _sources[id] = payload;
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronousCall) {
        stream.removeListener(listener);
        _readyIds.add(id);
        notifyLoaded();
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        _fullResFailures[id] = payload;
        evict(id);
      },
    );
    stream.addListener(listener);
  }

  /// Records that a full-resolution upgrade failed for THIS payload object, so
  /// the next 250ms settle does not re-buy a 61-406ms decode that just failed.
  void markFullResFailure(String id, SourcePayload payload) {
    _fullResFailures[id] = payload;
  }

  /// Removes [id]'s tier-2 bookkeeping and evicts its ImageCache entry (if
  /// any). Never touches tier-1 keys or the payload cache -- tier-1 and
  /// retention have their own, separate lifecycles.
  ///
  /// Note what is NOT here: no dispose, no in-flight marker to clear, no
  /// evict-before-dispose ordering. Evicting an ImageCache entry can no longer
  /// destroy anything the pipeline still needs, because what the pipeline keeps
  /// is the payload, and the payload is bytes.
  ///
  /// The failure memo is deliberately NOT cleared here: its lifetime is the
  /// payload's, not the entry's.
  void evict(String id) {
    final key = _keys.remove(id);
    _sources.remove(id);
    _readyIds.remove(id);
    if (key != null) {
      _imageCache.evict(key);
    }
  }

  /// The tier-2 slice of both `reset()` and `dispose()`: evict every registered
  /// entry, then drop all four containers.
  void clear() {
    for (final key in _keys.values) {
      _imageCache.evict(key);
    }
    _keys.clear();
    _sources.clear();
    _readyIds.clear();
    _fullResFailures.clear();
  }
}
