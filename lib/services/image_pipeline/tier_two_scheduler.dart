import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../models/photo_item.dart';
import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'photo_payload.dart';
import 'photo_payload_cache.dart';
import 'prefetch_scheduler.dart';
import 'serial_decode_lane.dart';
import 'tier_two_registry.dart';

/// Produces and retains an item's payload if it is not retained already --
/// bound to `ImagePreloadController._ensurePayload`.
///
/// Injected rather than reached through the controller, because payload
/// production owns the retention window, the permanent-miss sets and the
/// in-flight bookkeeping, none of which the scheduler may see.
typedef EnsurePayload =
    Future<void> Function(
      PhotoItem item, {
      required int distance,
      required VoidCallback? notifyLoaded,
      bool onSerialLane,
    });

/// Builds the tier-2 (full size, unresized) provider for a payload -- bound to
/// `ImagePreloadController._fullSizeProviderForPayload`.
///
/// It is a SUPPLIER, not a copy: the tier-1 and tier-2 provider factories must
/// stay side by side in the controller, because their pairing is the visible
/// statement of the "same payload object identity == same ImageCache key"
/// invariant (I1). Rebuilding a tier-2 provider here would be a second place
/// that decides what a payload's cache key is.
typedef FullSizeProviderFor = ImageProvider Function(SourcePayload payload);

/// Owns the TIER-2 SCHEDULING that used to live inline in
/// [ImagePreloadController]: WHEN a full-size decode happens (the 250ms
/// navigation debounce), FOR WHICH items (the +/-[kTierTwoRadius] window), and
/// IN WHAT ORDER (one sequential queue: payload production in index order
/// first, then full-resolution upgrades by distance).
///
/// It is deliberately a THIRD unit, not an extension of [TierTwoRegistry]. The
/// registry answers "what entry exists for this id, for which payload object,
/// is it ready, did its upgrade fail" from four containers and one lookup --
/// pure state, no async, no timers. Everything here is the opposite: timers,
/// windows, a serialised future chain, an FFI decode. Merging them would put
/// the readiness conjunction back in the same class as the scheduling state it
/// was extracted away from (AD-027: the four containers must not be re-split,
/// and equally must not be re-joined to scheduling).
///
/// Every collaborator arrives as a closure. The scheduler never holds the
/// payload cache, the photo source, the prefetch scheduler or the controller
/// itself, so retention, source selection and rung policy each stay
/// single-owned.
class TierTwoScheduler {
  TierTwoScheduler({
    required TierTwoRegistry registry,
    required SerialDecodeLane lane,
    required SourcePayload? Function(String id) currentPayloadFor,
    required FullSizeProviderFor fullSizeProviderFor,
    required EnsurePayload ensurePayload,
    required DngFullDecoder? Function() dngDecoder,
    required int? Function(String id) exifOrientationFor,
    required Duration navigationDebounce,
  }) : _registry = registry,
       _lane = lane,
       _currentPayloadFor = currentPayloadFor,
       _fullSizeProviderForPayload = fullSizeProviderFor,
       _ensurePayload = ensurePayload,
       _dngDecoder = dngDecoder,
       _exifOrientationFor = exifOrientationFor,
       _navigationDebounce = navigationDebounce;

  final TierTwoRegistry _registry;

  /// The pipeline's ONE serial decode lane, shared with the controller's
  /// payload production (user ruling 2026-08-26). It used to be a private
  /// `Future _queue` field here, which made "one RAW decode in flight" a
  /// property of THIS class only -- once payload production got a serial lane
  /// of its own, two private queues would have meant two concurrent decodes.
  final SerialDecodeLane _lane;
  final SourcePayload? Function(String id) _currentPayloadFor;
  final FullSizeProviderFor _fullSizeProviderForPayload;
  final EnsurePayload _ensurePayload;

  /// The RAW decoder, read through a supplier rather than captured once: it is
  /// `PhotoSource.dngDecoder`, and the source belongs to the controller.
  final DngFullDecoder? Function() _dngDecoder;

  /// The EXIF orientation the content probe already read (invariant I6): no
  /// bridge round trip is bought here to rotate a frame. The memo lives for the
  /// whole folder and is owned by the controller, so this is a read-only view.
  final int? Function(String id) _exifOrientationFor;

  /// `tierTwoNavigationDebounce`, passed in rather than imported so this file
  /// does not import the controller back.
  final Duration _navigationDebounce;

  Timer? _debounceTimer;

  // The ids the MOST RECENT tier-2 sweep was for. A source started by that
  // sweep finishes asynchronously, and by then the window may have moved; this
  // is what its completion re-checks itself against.
  Set<String> _windowIds = {};

  /// Whether [id] is in the window the most recent sweep was for. The
  /// controller's payload-production path asks this before riding the piggyback
  /// route, which is the one tier-2 decision taken outside this class.
  bool isInWindow(String id) => _windowIds.contains(id);

  /// Publishes the +/-[kTierTwoRadius] id set for [currentIndex] IMMEDIATELY,
  /// without arming or disturbing the debounce.
  ///
  /// Called by the controller at the top of every navigation pass, and it has
  /// to be: since the 2026-08-26 ruling an expensive decode can land at any
  /// moment on the serial lane, including well before the 250ms debounce
  /// fires, and the piggyback publish asks [isInWindow] to decide whether the
  /// full-resolution byproduct it is holding is worth keeping. While that set
  /// was only written when the debounce FIRED, a decode that finished first
  /// saw an empty/stale window, dropped free full-resolution pixels, and the
  /// catch-up upgrade then bought a SECOND FFI decode for them -- the exact
  /// "exactly one decoder call" guarantee AC-M5-4 pins.
  ///
  /// Only the id set moves earlier. WHEN full-size decodes run is still the
  /// debounce's business, and the +/-2 radius is unchanged.
  void updateWindow(List<PhotoItem> items, int currentIndex) {
    _windowIds = retentionWindowIds<PhotoItem>(
      items,
      currentIndex,
      (item) => item.id,
      before: kTierTwoRadius,
      after: kTierTwoRadius,
    );
  }

  /// Cancels a pending debounce. The tier-2 slice of both `reset()` and
  /// `dispose()`; the registry's own `clear()` stays a separate call, because
  /// state and scheduling have separate owners.
  void cancelDebounce() {
    _debounceTimer?.cancel();
  }

  // Tier-2 debounce: every navigation event cancels and reschedules this
  // timer, so only the FINAL position after a burst of navigation ever starts
  // a full-size decode or an expensive source -- items merely passed through
  // are never queued, because their scheduling attempt is cancelled before it
  // fires.
  //
  // Unlike before M3, this timer carries NO image-lifetime responsibility. It
  // is a pure performance device now: shortening or removing it can cost
  // decodes, but it can no longer dispose something out from under the display,
  // because nothing is disposed at all (design §4, invariant I7).
  void schedule(
    List<PhotoItem> items,
    int currentIndex,
    VoidCallback notifyLoaded,
  ) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_navigationDebounce, () {
      _decodeWindow(items, currentIndex, notifyLoaded);
    });
  }

  // Tier-2 precache: decode current +/-kTierTwoRadius at full size once
  // navigation has paused, and start the expensive sources that the immediate
  // pass deferred. Both tiers coexist: this only evicts its own window's
  // ImageCache entries and never touches the tier-1 keys or the payload cache --
  // payload retention is the -3..+5 rule and belongs to preloadImages alone.
  //
  // The span here is kTierTwoRadius (2) and it governs FULL-SIZE decodes only.
  // Since the 2026-08-26 ruling it no longer has anything to say about where an
  // expensive source may be STARTED: the window pass in the controller already
  // queues every missing payload in the -3..+5 retention window on the shared
  // serial lane. What this loop still owns is the catch-up case -- a slot that
  // is inside the +/-2 band and still has no payload when the debounce fires
  // gets (re-)queued here WITH its tier-2 decode chained on, because if the
  // user has stopped navigating there is no later pass to flip readiness.
  void _decodeWindow(
    List<PhotoItem> items,
    int currentIndex,
    VoidCallback notifyLoaded,
  ) {
    final tierStart = (currentIndex - kTierTwoRadius).clamp(
      0,
      items.length - 1,
    );
    final tierEnd = (currentIndex + kTierTwoRadius).clamp(
      0,
      items.length - 1,
    );
    // The iteration bounds above and the id set below are recomputed from the
    // same constants rather than one derived from the other, so the ordered
    // loop range and the (unordered) neededIds set cannot disagree. The loop
    // below still walks tierStart..tierEnd (not neededIds) because iterating
    // an unordered Set here would change the tier-2 decode ORDER, which is
    // load-bearing for the sequential queue.
    final neededIds = retentionWindowIds<PhotoItem>(
      items,
      currentIndex,
      (item) => item.id,
      before: kTierTwoRadius,
      after: kTierTwoRadius,
    );
    _windowIds = neededIds;

    final pendingUpgrades =
        <({PhotoItem item, PixelPayload payload, int distance})>[];

    for (var i = tierStart; i <= tierEnd; i++) {
      final item = items[i];
      final payload = _currentPayloadFor(item.id);
      if (payload == null) {
        // Not fetched yet: either still queued on the serial lane, or a cheap
        // load that has not landed. Its tier-2 decode has to be chained onto
        // the load rather than left for "the next pass": if the user stops
        // navigating here, there IS no next pass, and readiness would never
        // flip -- the payload would be retained and the view would keep showing
        // a spinner. The window re-check is what keeps a late arrival from
        // decoding for a position the user has already left.
        _enqueueLoad(
          item,
          distance: i - currentIndex,
          notifyLoaded: notifyLoaded,
        );
        continue;
      }
      // Only skip if the ready flag was set for THIS payload -- if the item's
      // payload was replaced since the last decode (e.g. it briefly left the
      // retention window), the flag is stale and the decode must be redone
      // against the current object (round-2 review BLOCKER 1).
      final alreadyDecoded = _registry.isReady(item.id);
      if (alreadyDecoded) continue;
      switch (payload) {
        case EncodedPayload():
          // Verbatim today's behaviour. The cheap path is the floor: M5 adds
          // nothing to it and takes nothing away.
          _registry.publishEncoded(
            item.id,
            payload,
            _fullSizeProviderForPayload(payload),
            notifyLoaded,
          );
        case PixelPayload():
          // The CATCH-UP upgrade (design §2.2): this item already has its
          // window-resolution payload but no full-resolution entry -- it slid
          // into the +/-2 band, or left and came back after its entry was
          // evicted. Unlike the piggyback path there is no decode in flight to
          // ride along on, so it costs one FFI decode, taken on the SAME serial
          // lane as payload production (no new concurrency) and behind the same
          // window re-check.
          //
          // Collected rather than enqueued here, so the lane order is the one
          // the user ruled on (open question 4): payload production -- the
          // blank slots the user can SEE -- goes in first, then upgrades
          // near-to-far. [kFullResPriorityBase] is what makes that ordering
          // hold even against a payload task queued after this loop ran.
          pendingUpgrades.add((
            item: item,
            payload: payload,
            distance: i - currentIndex,
          ));
      }
    }

    pendingUpgrades.sort(
      (a, b) => laneRankFor(a.distance).compareTo(laneRankFor(b.distance)),
    );
    for (final upgrade in pendingUpgrades) {
      _enqueueFullResUpgrade(
        upgrade.item,
        upgrade.payload,
        upgrade.distance,
        notifyLoaded,
      );
    }

    final staleIds = _registry.keyIds
        .where((id) => !neededIds.contains(id))
        .toList();
    for (final id in staleIds) {
      _registry.evict(id);
    }
  }

  /// Queues a tier-2 CATCH-UP load on the shared serial lane: produce the
  /// payload, then chain its full-size decode onto the same task.
  ///
  /// Runs ONE AT A TIME because the lane runs one at a time. A RAW decode
  /// saturates cores rather than waiting on IO, so N in parallel is slower per
  /// image AND makes the selected item contend with its neighbours. The
  /// latency trade is the intended one (user clarification: "no embedded JPEG
  /// -> sequential RAW decode").
  ///
  /// It shares the lane KEY SPACE with the controller's payload production, so
  /// an item already queued there is re-ranked and given this richer body
  /// rather than decoded twice.
  ///
  /// The debounce itself is untouched (Amendment 3 clause 3).
  void _enqueueLoad(
    PhotoItem item, {
    required int distance,
    required VoidCallback notifyLoaded,
  }) {
    _lane.enqueue(
      (LaneTaskKind.payload, item.id),
      priority: laneRankFor(distance),
      body: () => _runLoadAndChainTierTwo(item, distance, notifyLoaded),
    );
  }

  Future<void> _runLoadAndChainTierTwo(
    PhotoItem item,
    int distance,
    VoidCallback notifyLoaded,
  ) async {
    // Re-checked HERE, not only at enqueue time: by the time this item's turn
    // comes the user may have navigated away, and decoding for a position
    // nobody is looking at is exactly what the lane exists to prevent.
    if (!_windowIds.contains(item.id)) return;
    await _ensurePayload(
      item,
      distance: distance,
      notifyLoaded: notifyLoaded,
      onSerialLane: true,
    );
    // The tier-2 decode is chained onto the load rather than left for "the
    // next pass": if the user stops navigating here there IS no next pass,
    // and readiness would never flip -- the payload would be retained and
    // the view would keep showing a spinner.
    final landed = _currentPayloadFor(item.id);
    if (landed == null || !_windowIds.contains(item.id)) return;
    if (landed is PixelPayload) {
      // The load above ran the FFI decode and, on success, ALREADY published
      // the full-resolution entry by piggyback (design §2.2) -- that is what
      // makes the pair "payload + full-res tier-2" cost exactly one decoder
      // call. Anything left to do here is the catch-up case (the payload was
      // already cached, so no decode ran), and it is run INLINE because this
      // is already the serial lane's task body.
      if (_registry.hasFullResEntryFor(item.id, landed)) return;
      await _upgradeFullRes(item, landed, notifyLoaded);
      return;
    }
    assert(landed is EncodedPayload);
    _registry.publishEncoded(
      item.id,
      landed,
      _fullSizeProviderForPayload(landed),
      notifyLoaded,
    );
  }

  // Queues a catch-up full-resolution upgrade on the SAME serial lane the
  // expensive payload loads use, under the fullRes key kind so it cannot
  // collide with (or supersede) the payload task for the same item. Its
  // priority sits behind every pending payload task: the blank slots the user
  // can SEE go first (user ruling, open question 4).
  //
  // The window re-check is inside the queued body (not at enqueue time) for the
  // same reason it is in [_enqueueLoad]: by the time this item's turn comes the
  // user may have navigated away.
  void _enqueueFullResUpgrade(
    PhotoItem item,
    PixelPayload payload,
    int distance,
    VoidCallback notifyLoaded,
  ) {
    _lane.enqueue(
      (LaneTaskKind.fullRes, item.id),
      priority: kFullResPriorityBase + laneRankFor(distance),
      body: () async {
        if (!_windowIds.contains(item.id)) return;
        if (!identical(_currentPayloadFor(item.id), payload)) return;
        if (_registry.hasFullResEntryFor(item.id, payload)) return;
        await _upgradeFullRes(item, payload, notifyLoaded);
      },
    );
  }

  // One FFI decode -> full-resolution oriented image -> ImageCache. The
  // window-resolution byproduct is NOT produced and the retained payload object
  // is NEVER replaced: replacing it would invalidate the tier-1 ImageCache key
  // and the identity assertions the frozen navigation probes rest on.
  Future<void> _upgradeFullRes(
    PhotoItem item,
    PixelPayload payload,
    VoidCallback notifyLoaded,
  ) async {
    final id = item.id;
    // Failed once for THIS payload: do not re-buy a 61-406ms decode on every
    // settle. The memo dies with the payload (design §2.5).
    if (_registry.hasFullResFailure(id, payload)) return;
    final decoder = _dngDecoder();
    final file = item.bestFileToLoad;
    // Orientation comes from the memo the probe already filled (invariant I6):
    // no bridge round trip is bought to rotate a frame.
    final orientation = _exifOrientationFor(id);
    if (decoder == null || file == null || orientation == null) {
      _registry.markFullResFailure(id, payload);
      return;
    }

    ui.Image image;
    try {
      final decoded = await decoder(file.path);
      image = await decodedRgbaToImage(decoded, exifOrientation: orientation);
    } catch (_) {
      // Tier-1 display is untouched and this is NOT a permanent miss: the
      // item has a payload and is on screen (design §2.5).
      _registry.markFullResFailure(id, payload);
      return;
    }

    // Re-checked after the await, per invariant I4: the window may have moved
    // or the payload been replaced while the decode ran, in which case the
    // image is released HERE rather than stored anywhere.
    if (!_windowIds.contains(id) ||
        !identical(_currentPayloadFor(id), payload)) {
      image.dispose();
      return;
    }
    _registry.publishFullRes(id, payload, image, notifyLoaded);
  }

  /// The PIGGYBACK half of design §2.2: the pixels handed back alongside the
  /// window-resolution payload by the single decode that just ran. They are
  /// already oriented and full-resolution, so all that is left is one GPU
  /// upload. The buffer is a parameter and a local only -- it is never stored
  /// in a field, so nothing outlives this call except the ImageCache entry.
  ///
  /// Public because it is reached from the controller's payload-production
  /// path, which is where the decode that produced these pixels ran.
  Future<void> publishPiggybackFullRes(
    String id,
    PixelPayload payload,
    ({Uint8List rgba, int width, int height}) fullRes,
    VoidCallback? notifyLoaded,
  ) async {
    if (fullRes.rgba.lengthInBytes != fullRes.width * fullRes.height * 4) {
      return;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      fullRes.rgba,
      fullRes.width,
      fullRes.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    // Same post-await re-check as the catch-up path; releases in place.
    if (!_windowIds.contains(id) ||
        !identical(_currentPayloadFor(id), payload)) {
      image.dispose();
      return;
    }
    _registry.publishFullRes(id, payload, image, notifyLoaded ?? () {});
  }
}
