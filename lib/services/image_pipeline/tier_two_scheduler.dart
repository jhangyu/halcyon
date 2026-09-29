import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../models/photo_item.dart';
import '../../perf/perf_log.dart'; // PERF-INSTRUMENTATION (D1 round-2 additions)
import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'frame_bytes.dart';
import 'idle_publish_scheduler.dart';
import 'photo_payload.dart';
import 'photo_payload_cache.dart';
import 'prefetch_scheduler.dart';
import 'decode_lane.dart';
import 'lane_priority.dart';
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

/// The pacing seam that gates every tier-2 full-resolution `ui.Image`
/// hand-off to the registry (contract deliverable 2,
/// docs/logs/2026-09-04/pacer-followup-contract.md). Signature-identical to
/// `PublicationPacer.submit` (`publication_pacer.dart`), so the production
/// binding is that method's tear-off directly -- no wrapper, no second
/// pacing mechanism. Kept as a typedef here (not an import of
/// `PublicationPacer`) so this file does not need to know the pacer's
/// concrete type, only its shape.
typedef PublishPacer =
    void Function({
      required String id,
      required int rank,
      required bool exempt,
      required bool Function() stillValid,
      required void Function() publish,
      void Function()? discard,
      // R3-WP8 (plan Step 9.5): mirrors `PublicationPacer.submit`'s now-
      // required `byteCost`, so the production tearoff binds without a
      // wrapper.
      required int byteCost,
    });

/// The default binding: publish immediately when still valid, otherwise
/// discard. Every existing construction (and every pre-existing test) gets
/// this, so adding the [PublishPacer] parameter changes no existing call
/// site's behaviour.
void immediatePublishPacer({
  required String id,
  required int rank,
  required bool exempt,
  required bool Function() stillValid,
  required void Function() publish,
  void Function()? discard,
  required int byteCost,
}) {
  if (stillValid()) {
    publish();
  } else {
    discard?.call();
  }
}

/// Contract deliverable 3: the ONE definition of "is this the currently
/// selected item", shared by every `exempt:` call site instead of each
/// computing its own copy of the same predicate
/// (docs/logs/2026-09-03/pacer-exempt-path-audit.md Finding 2 -- two
/// tier-1 call sites independently wrote `distance == 0` and
/// `i == currentIndex`, which are the same fact expressed two ways). `distance`
/// is `index - currentIndex` (or, for the piggyback/upgrade paths, the
/// distance captured when the item's slot was enqueued): 0 means the
/// selected item.
bool isSelectedExempt(int distance) => distance == 0;

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
/// navigation debounce), FOR WHICH items (the full-resolution band,
/// [kFullResolutionBandRadius]), and
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
    required DecodeLane lane,
    required SourcePayload? Function(String id) currentPayloadFor,
    required FullSizeProviderFor fullSizeProviderFor,
    required EnsurePayload ensurePayload,
    required DngFullDecoder? Function() dngDecoder,
    required int? Function(String id) exifOrientationFor,
    required Duration navigationDebounce,
    CompositeGate compositeGate = immediateCompositeGate,
    PublishPacer publishPacer = immediatePublishPacer,
  }) : _registry = registry,
       _lane = lane,
       _currentPayloadFor = currentPayloadFor,
       _fullSizeProviderForPayload = fullSizeProviderFor,
       _ensurePayload = ensurePayload,
       _dngDecoder = dngDecoder,
       _exifOrientationFor = exifOrientationFor,
       _navigationDebounce = navigationDebounce,
       _compositeGate = compositeGate,
       _publishPacer = publishPacer;

  /// Count of catch-up re-enqueues issued by [_enqueueLoad] (the sweep path
  /// TC-984 exists to pin the order of). Incremented, never reset, so a test
  /// can assert the sweep actually fired at least once rather than trusting
  /// that the merged-order assertions imply it (they do not discriminate a
  /// sweep that never ran from one that ran and was correctly ordered by
  /// accident -- see docs/logs/2026-09-06/async-pipeline-campaign-handover.md
  /// §9). Zero behavior change: read-only, incremented alongside the existing
  /// enqueue call. Not itself `@visibleForTesting` -- it is forwarded through
  /// [ImagePreloadController.debugCatchUpEnqueueCount], which carries the
  /// annotation for the one call site that matters (this is an internal
  /// collaborator of the controller, not a public API surface of its own).
  int debugCatchUpEnqueueCount = 0;

  /// How many band-entry promotions had to buy a decode of the ORIGINAL
  /// FILE (the pre-v2 route). Zero is the steady-state expectation once
  /// every retained slot carries a full-size JPEG; non-zero means a promotion
  /// found no q70 payload able to serve full-resolution pixels and had to
  /// decode the original file (spec R5's counted fallback).
  ///
  /// Incremented, never reset -- same discipline as
  /// [debugCatchUpEnqueueCount]: a resettable counter cannot distinguish
  /// "never happened" from "happened and was cleared". Forwarded through
  /// [ImagePreloadController.debugBandEntryFileDecodeCount], which carries
  /// the `@visibleForTesting` annotation for the one call site that
  /// matters.
  int debugBandEntryFileDecodeCount = 0;

  /// How many tier-2 full-resolution publishes were served BY DECODING THE q70
  /// PAYLOAD (spec R2's single route). Incremented once per submission accepted
  /// by [publishFromPayload], never reset -- same discipline as
  /// [debugBandEntryFileDecodeCount]: a resettable counter cannot distinguish
  /// "never happened" from "happened and was cleared".
  int debugPayloadDecodePublishCount = 0;

  /// SR-8. Bytes this class has charged to the shared in-flight ledger at its
  /// full-res-upgrade enqueue site, accumulated and never reset.
  ///
  /// DELIBERATELY NOT AGGREGATED with
  /// `DeferredFullSizeEncoder.debugChargedBytes`: the spec's mechanical check
  /// is that each off-ledger path is separately attributable, and a single
  /// combined figure cannot distinguish "both paths charge" from "one path
  /// charges twice". Same incremented-never-reset discipline as
  /// [debugBandEntryFileDecodeCount].
  int debugChargedBytes = 0;

  final TierTwoRegistry _registry;

  /// The pipeline's ONE serial decode lane, shared with the controller's
  /// payload production (user ruling 2026-08-26). It used to be a private
  /// `Future _queue` field here, which made "one RAW decode in flight" a
  /// property of THIS class only -- once payload production got a serial lane
  /// of its own, two private queues would have meant two concurrent decodes.
  final DecodeLane _lane;
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

  /// Pacing seam for this class's `decodedRgbaToImage` compositing pass
  /// (contract deliverable 2). Defaults to no pacing.
  final CompositeGate _compositeGate;

  /// Pacing seam for [publishFullRes] hand-offs (contract deliverable 2).
  /// Defaults to unpaced (immediate) publication.
  final PublishPacer _publishPacer;

  /// id -> the payload a full-res publish has been SUBMITTED to the pacer
  /// for, but which has not yet landed in the registry (a non-exempt
  /// submission that is still queued, or was queued at some point before
  /// this decode completed).
  ///
  /// Without this, pacing a non-selected item's publish reopened exactly the
  /// "exactly one decoder call" hole AC-M5-4 closed: `_decodeWindow`'s
  /// catch-up filter and `_enqueueFullResUpgrade`/`_runLoadAndChainTierTwo`'s
  /// pre-decode guards all ask [TierTwoRegistry.hasFullResEntryFor] /
  /// [TierTwoRegistry.isReady], and both read `_registry`'s containers, which
  /// a QUEUED (not yet drained) pacer submission has not written to yet --
  /// so a debounce settle landing while the first decode's publish still sits
  /// in the pacer's queue would see "no entry" and buy a SECOND FFI decode
  /// for the same id (caught by TC-430's decoder-call-count regression during
  /// this round's implementation; see
  /// docs/logs/2026-09-04/r1-pacer2-verify.txt).
  ///
  /// Cleared by [_publishOrDiscard] exactly once the pacer resolves the
  /// submission, published or discarded, mirroring the registry's own
  /// per-payload-object bookkeeping.
  final Map<String, SourcePayload> _pendingFullResPublish = {};

  /// True when [id]'s full-res publish for [payload] either already landed
  /// in the registry, or is queued in the pacer waiting to. Every
  /// pre-decode guard that used to ask only [TierTwoRegistry.hasFullResEntryFor]
  /// must ask this instead, now that a publish can be paced.
  bool _hasFullResClaimFor(String id, SourcePayload payload) =>
      _registry.hasFullResEntryFor(id, payload) ||
      identical(_pendingFullResPublish[id], payload);

  /// Submits [image] to the pacer, tracking the claim in
  /// [_pendingFullResPublish] for the submission's lifetime so no other
  /// caller buys a redundant decode while it is queued.
  void _publishOrDiscard(
    String id,
    SourcePayload payload,
    int distance,
    ui.Image image,
    VoidCallback notifyLoaded, {
    // PERF-INSTRUMENTATION (D1 round-2, H2): 'upgrade' vs 'piggyback',
    // forwarded to [TierTwoRegistry.publishFullRes]'s own `source` tag.
    String source = 'publishFullRes',
  }) {
    _pendingFullResPublish[id] = payload;
    final exempt = isSelectedExempt(distance);
    // PERF-INSTRUMENTATION (D1 AC3 marker + gap #3): submit timestamp, so
    // round-2 analysis can derive submit->publish (land) latency by matching
    // this id against the later `publish` line -- H3's 32ms safeguard tax.
    PerfLog.log(
      'submit|id=$id|path=$source|exempt=$exempt|paced=${!exempt}'
      '|rank=${laneRankFor(distance)}',
    );
    _publishPacer(
      id: id,
      rank: laneRankFor(distance),
      exempt: exempt,
      stillValid: () =>
          _windowIds.contains(id) && identical(_currentPayloadFor(id), payload),
      // R3-WP8 (plan Step 9.4): `image.width * image.height * 4`, NOT
      // `rgba.length` -- WP4 empties `rgba` on the rotated path, which would
      // charge 0 for exactly the most expensive publications.
      byteCost: image.width * image.height * 4,
      publish: () {
        if (identical(_pendingFullResPublish[id], payload)) {
          _pendingFullResPublish.remove(id);
        }
        _registry.publishFullRes(id, payload, image, notifyLoaded, source: source);
      },
      discard: () {
        if (identical(_pendingFullResPublish[id], payload)) {
          _pendingFullResPublish.remove(id);
        }
        image.dispose();
      },
    );
  }

  /// The [EncodedPayload] counterpart to [_publishOrDiscard] (contract
  /// deliverable, docs/logs/2026-09-04/remediation-round-contract.md W2):
  /// before this, `publishEncoded` was called directly from both call sites
  /// below, bypassing the pacer entirely (148 unpaced publishes, residual-
  /// jank-diagnosis.md #7). Routed through the SAME [_publishPacer] seam and
  /// tracked in the SAME [_pendingFullResPublish] claim map as the pixel
  /// path, so the `alreadyDecoded` re-check in [_decodeWindow] sees a queued
  /// (not yet landed) encoded publish exactly like a queued full-res one --
  /// preventing a second submission for the same id/payload while the first
  /// is still paced. Unlike a `ui.Image`, an [ImageProvider] built over
  /// already-retained payload bytes needs no disposal on discard.
  void _publishEncodedOrDiscard(
    String id,
    SourcePayload payload,
    int distance,
    ImageProvider provider,
    VoidCallback notifyLoaded,
  ) {
    _pendingFullResPublish[id] = payload;
    final exempt = isSelectedExempt(distance);
    // PERF-INSTRUMENTATION (D1 AC3 marker + gap #3, H2): mirrors the submit
    // line [_publishOrDiscard] emits for the pixel path -- this is what makes
    // this path's `paced=` value real instead of the previous structural
    // `paced=false` claim.
    PerfLog.log(
      'submit|id=$id|path=publishEncoded|exempt=$exempt|paced=${!exempt}'
      '|rank=${laneRankFor(distance)}',
    );
    _publishPacer(
      id: id,
      rank: laneRankFor(distance),
      exempt: exempt,
      stillValid: () =>
          _windowIds.contains(id) && identical(_currentPayloadFor(id), payload),
      // R3-WP8 (plan Step 9.4): no `ui.Image` on this path -- it publishes an
      // `ImageProvider` over already-retained payload bytes, so the cost is
      // the payload's own byteCost.
      byteCost: payload.byteCost,
      publish: () {
        if (identical(_pendingFullResPublish[id], payload)) {
          _pendingFullResPublish.remove(id);
        }
        _registry.publishEncoded(id, payload, provider, notifyLoaded);
      },
      discard: () {
        if (identical(_pendingFullResPublish[id], payload)) {
          _pendingFullResPublish.remove(id);
        }
      },
    );
  }

  Timer? _debounceTimer;

  // Synchronous in-flight claim for [_upgradeFullRes], taken BEFORE any await
  // (S-1 fix, third instance of the check-then-act-across-await shape, see
  // G-NNN in memory.md / docs/logs/2026-08-30/lane-race-sop-updates.md §1).
  // The inline chained upgrade (`_runLoadAndChainTierTwo`) and the queued
  // upgrade (`_enqueueFullResUpgrade`) enqueue under DIFFERENT lane keys for
  // the same photo id, so `DecodeLane`'s key-dedup cannot dedupe them: at lane
  // width >= 2 both callers can pass their pre-await `hasFullResEntryFor`
  // check and both reach here before either has published. This set makes the
  // second entrant a no-op instead of a second FFI decode. The registry's
  // first-writer-wins guard in `publishFullRes` stays as the correctness
  // backstop; this claim only saves the wasted decode + transient memory
  // peak. Released in a `finally` so every exit path (early failure returns,
  // the decode catch, the post-await stale-window/payload return, and the
  // success path) releases exactly once.
  final Set<String> _upgradesInFlight = <String>{};

  // The ids the MOST RECENT tier-2 sweep was for. A source started by that
  // sweep finishes asynchronously, and by then the window may have moved; this
  // is what its completion re-checks itself against.
  Set<String> _windowIds = {};

  /// Whether [id] is in the window the most recent sweep was for. The
  /// controller's payload-production path asks this before riding the piggyback
  /// route, which is the one tier-2 decision taken outside this class.
  bool isInWindow(String id) => _windowIds.contains(id);

  /// Publishes the +/-[kFullResolutionBandRadius] id set for [currentIndex]
  /// IMMEDIATELY,
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
  /// debounce's business, and the band shape is unchanged.
  void updateWindow(List<PhotoItem> items, int currentIndex) {
    _windowIds = retentionWindowIds<PhotoItem>(
      items,
      currentIndex,
      (item) => item.id,
      before: kFullResolutionBandRadius,
      after: kFullResolutionBandRadius,
    );
  }

  /// The full-resolution band id set the PREVIOUS [schedule] call saw. Diffed
  /// against the current band to find the items that NEWLY entered it, which
  /// start decoding immediately (user ruling 2026-09-11 22:00; see
  /// [_startNewBandEntrants]).
  ///
  /// Separate from [_windowIds] on purpose: `updateWindow` runs BEFORE
  /// `schedule` in the controller's navigation pass and has already overwritten
  /// `_windowIds` with the new set by the time the diff is taken, so the diff
  /// needs its own memo of the previous position.
  Set<String> _bandEntryScanned = {};

  /// Cancels a pending debounce. The tier-2 slice of both `reset()` and
  /// `dispose()`; the registry's own `clear()` stays a separate call, because
  /// state and scheduling have separate owners.
  void cancelDebounce() {
    _debounceTimer?.cancel();
    // A folder switch (reset) or teardown invalidates the band-entry memo: an
    // id from the old folder must not suppress the immediate start it would
    // otherwise get on the next pass.
    _bandEntryScanned = {};
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
    // USER RULING 2026-09-11 22:00: an item that NEWLY enters the +/-1 band
    // starts decoding IMMEDIATELY, without waiting out the debounce. See
    // [_startNewBandEntrants]. The debounce below still owns the window SCAN
    // (catch-up for items that were already in the band, plus stale eviction)
    // and its constant is unchanged.
    _startNewBandEntrants(items, currentIndex, notifyLoaded);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_navigationDebounce, () {
      _decodeWindow(items, currentIndex, notifyLoaded);
    });
  }

  /// Starts the full-resolution decode for the items that entered the
  /// +/-[kFullResolutionBandRadius] band on THIS navigation pass, synchronously.
  ///
  /// Why this exists (docs/logs/2026-09-11/wp42-latency-regression-diagnosis.md):
  /// the only tier-2 enqueue point used to sit inside the 250ms debounce timer.
  /// While the band reached +3 that cost was amortised -- one debounce firing
  /// started three steps' worth of lookahead -- but at a symmetric +/-1 band a
  /// sequential walker pays a nearly-unamortised debounce on every step, which
  /// measured as a 101.5ms -> 253.5ms median regression.
  ///
  /// Scope, deliberately narrow:
  /// * only ids that were NOT in the band on the previous pass are dispatched,
  ///   so a burst of navigation does not re-dispatch the items it is passing
  ///   through more than once each;
  /// * the band SHAPE, the eviction bands and the debounce constant are
  ///   untouched, and this path never evicts anything -- stale eviction stays
  ///   the debounced sweep's job;
  /// * dedup is the existing machinery ([_registry.isReady],
  ///   [_pendingFullResPublish], [_hasFullResClaimFor], the lane's key dedup),
  ///   so an item already decoding or published is a no-op here.
  void _startNewBandEntrants(
    List<PhotoItem> items,
    int currentIndex,
    VoidCallback notifyLoaded,
  ) {
    if (items.isEmpty) return;
    final tierStart = (currentIndex - kFullResolutionBandRadius).clamp(
      0,
      items.length - 1,
    );
    final tierEnd = (currentIndex + kFullResolutionBandRadius).clamp(
      0,
      items.length - 1,
    );
    final previous = _bandEntryScanned;
    final current = <String>{};
    final entrants = <int>[];
    for (var i = tierStart; i <= tierEnd; i++) {
      final id = items[i].id;
      current.add(id);
      if (!previous.contains(id)) entrants.add(i);
    }
    _bandEntryScanned = current;
    // The dispatch below re-checks `_windowIds`, so the id set has to be
    // truthful before it runs. In production [updateWindow] has already written
    // exactly this set earlier in the same synchronous navigation pass (same
    // items, same index, same constants), so this is a no-op there; writing it
    // here as well removes the dependency on that call ordering rather than
    // changing the set.
    _windowIds = current;
    if (entrants.isEmpty) return;
    _dispatchBandItems(
      items,
      entrants,
      currentIndex,
      notifyLoaded,
      // THE LOAD IS NOT THIS PATH'S BUSINESS, and this is the whole difference
      // between the two callers.
      //
      // A slot with no payload yet is ALREADY being produced: the controller's
      // navigation pass enqueues every missing payload in the -3..+5 retention
      // window on the shared serial lane in this same synchronous turn, and its
      // piggyback publish hands us the full-resolution entry for free when the
      // slot is in the band. Enqueuing a catch-up load from here as well put a
      // second, richer body on the lane for the same id on EVERY navigation
      // step -- measured as duplicated decodes, a starved byte gate and
      // paced-publication stalls across 17 controller-level tests.
      //
      // The regression this path exists to fix does not need it: a slot
      // entering the +/-1 band has almost always been sitting in the -3..+5
      // retention window with its payload already retained, and what it was
      // waiting 250ms for was the full-resolution DECODE of that payload, not
      // the payload. Catch-up loading for the genuinely cold slot stays the
      // debounced sweep's job, exactly as before this path existed.
      enqueueMissingLoads: false,
    );
  }

  // Tier-2 precache: decode the full-resolution band at full size once
  // navigation has paused, and start the expensive sources that the immediate
  // pass deferred. Both tiers coexist: this only evicts its own window's
  // ImageCache entries and never touches the tier-1 keys or the payload cache --
  // payload retention is the -3..+5 rule and belongs to preloadImages alone.
  //
  // The span here is the full-resolution band (kFullResolutionBandRadius) and
  // it governs FULL-SIZE decodes only.
  // Since the 2026-08-26 ruling it no longer has anything to say about where an
  // expensive source may be STARTED: the window pass in the controller already
  // queues every missing payload in the -3..+5 retention window on the shared
  // serial lane. What this loop still owns is the catch-up case -- a slot that
  // is inside the -1..+3 band and still has no payload when the debounce fires
  // gets (re-)queued here WITH its tier-2 decode chained on, because if the
  // user has stopped navigating there is no later pass to flip readiness.
  void _decodeWindow(
    List<PhotoItem> items,
    int currentIndex,
    VoidCallback notifyLoaded,
  ) {
    final tierStart = (currentIndex - kFullResolutionBandRadius).clamp(
      0,
      items.length - 1,
    );
    final tierEnd = (currentIndex + kFullResolutionBandRadius).clamp(
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
      before: kFullResolutionBandRadius,
      after: kFullResolutionBandRadius,
    );
    _windowIds = neededIds;

    _dispatchBandItems(
      items,
      [for (var i = tierStart; i <= tierEnd; i++) i],
      currentIndex,
      notifyLoaded,
      // The sweep is the only catch-up loader: if the user has stopped
      // navigating there is no later pass to flip readiness for a slot whose
      // payload never landed.
      enqueueMissingLoads: true,
    );

    final staleIds = _registry.keyIds
        .where((id) => !neededIds.contains(id))
        .toList();
    for (final id in staleIds) {
      _registry.evict(id);
    }
  }

  /// The per-slot tier-2 dispatch shared by the debounced sweep
  /// ([_decodeWindow], which passes the whole band) and the immediate
  /// band-entry path ([_startNewBandEntrants], which passes only the newly
  /// entered slots).
  ///
  /// [indices] is walked IN ORDER and must already be in the order the lane
  /// should see (the sweep hands it tierStart..tierEnd): iterating an unordered
  /// set here would change the tier-2 decode ORDER, which is load-bearing for
  /// the sequential queue. Collected `PixelPayload` upgrades are still sorted
  /// by lane rank before enqueue, so payload production -- the blank slots the
  /// user can SEE -- goes in ahead of them.
  ///
  /// This method NEVER evicts and never writes [_windowIds]: both belong to the
  /// callers ([updateWindow] owns the id set, the debounced sweep owns stale
  /// eviction).
  void _dispatchBandItems(
    List<PhotoItem> items,
    List<int> indices,
    int currentIndex,
    VoidCallback notifyLoaded, {
    required bool enqueueMissingLoads,
  }) {
    final pendingUpgrades =
        <({PhotoItem item, PixelPayload payload, int distance})>[];

    for (final i in indices) {
      final item = items[i];
      final payload = _currentPayloadFor(item.id);
      if (payload == null) {
        if (!enqueueMissingLoads) continue;
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
      // against the current object (round-2 review BLOCKER 1). Also skip a
      // payload whose full-res publish is already CLAIMED (landed or paced
      // and queued): a paced publish for a non-selected item has not written
      // the registry yet, and without this check this sweep would buy a
      // second, redundant decode for it (contract deliverable 2 regression,
      // TC-430).
      final alreadyDecoded = _registry.isReady(item.id) ||
          identical(_pendingFullResPublish[item.id], payload);
      if (alreadyDecoded) continue;
      switch (payload) {
        case EncodedPayload():
          // R2's single route. The pre-checks and the counter live inside it,
          // so this arm no longer re-derives them.
          publishFromPayload(
            item.id,
            payload,
            notifyLoaded,
            distance: i - currentIndex,
          );
        case PixelPayload():
          // The CATCH-UP upgrade (design §2.2): this item already has its
          // window-resolution payload but no full-resolution entry -- it slid
          // into the -1..+3 band, or left and came back after its entry was
          // evicted. Unlike the piggyback path there is no decode in flight to
          // ride along on, so it costs one FFI decode, taken on the SAME serial
          // lane as payload production (no new concurrency) and behind the same
          // window re-check.
          //
          // Collected rather than enqueued here, so the lane order is the one
          // the user ruled on (open question 4): payload production -- the
          // blank slots the user can SEE -- goes in first, then upgrades
          // near-to-far. The full-res BAND (lane_priority.dart) is what makes
          // that ordering hold even against a payload task queued after this
          // loop ran.
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
    debugCatchUpEnqueueCount++;
    _lane.enqueue(
      (LaneTaskKind.payload, item.id),
      // THE NAVIGATION BAND, not a raw rank. This enqueue shares the
      // `(payload, id)` key space with the controller's own production, and
      // DecodeLane RE-RANKS a pending key on re-enqueue -- so handing it a
      // bare 0..N rank here would silently pull whichever slots this sweep
      // touches (the tier-2 window, -1..+3) below every plain navigation slot
      // sitting at 1000+. Concretely: the -2 slot (1004) would lose to +3
      // (5), inverting the 2026-08-26 start-order ruling.
      //
      // Before Phase 4 this site and `_enqueueSerialLoad` both used
      // `laneRankFor`, so they agreed by accident; Phase 4 rebased that one
      // and missed this one. TC-984 is the regression pin, and it is the only
      // test that mixes the two producers.
      priority: navigationPriorityFor(distance),
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
      // A window-resolution payload: the load above produced no full-size
      // JPEG, so there is nothing to decode a full-res entry FROM. Run the
      // upgrade inline (this is already the serial lane's task body) -- it
      // will take the counted file fallback.
      //
      // (Pre-q70 this comment claimed the load had already published the
      // full-res entry "by piggyback". That route is deleted: decode no
      // longer produces display pixels at all -- spec R1/R2.)
      if (_hasFullResClaimFor(item.id, landed)) return;
      await _upgradeFullRes(item, landed, distance, notifyLoaded);
      return;
    }
    assert(landed is EncodedPayload);
    publishFromPayload(item.id, landed, notifyLoaded, distance: distance);
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
    // SR-8. This body buys a full FFI decode of the original file
    // (`_upgradeFullRes`, the `decoder(file.path)` call) and builds a
    // full-resolution `ui.Image` from it, on the SAME lane and against the
    // SAME budget as every other expensive decode -- but it used to enqueue
    // with no estimate, so those bytes were invisible to the gate that exists
    // to bound exactly them.
    //
    // Charged NOMINALLY, like the ordinary decode's own estimate at
    // `image_preload_controller.dart:2761`. Unlike that path this one never
    // reconciles to the real frame size via `InflightBytesBudget.adjust`;
    // known limitation, out of scope here, and the nominal is within ~1% of a
    // 24 MP frame.
    const estimate = kNominalFullFrameBytes;
    debugChargedBytes += estimate;
    _lane.enqueue(
      (LaneTaskKind.fullRes, item.id),
      // PHASE 4: the full-res band, from the one classifier. Its position --
      // after ALL payload production, before ALL sidebar work -- is a user
      // ruling (contract override S4), not a refactor choice.
      priority: fullResPriorityFor(distance),
      estimatedBytes: estimate,
      body: () async {
        if (!_windowIds.contains(item.id)) return;
        if (!identical(_currentPayloadFor(item.id), payload)) return;
        if (_hasFullResClaimFor(item.id, payload)) return;
        await _upgradeFullRes(item, payload, distance, notifyLoaded);
      },
    );
  }

  // One FFI decode -> full-resolution oriented image -> ImageCache. The
  // window-resolution byproduct is NOT produced and the retained payload object
  // is NEVER replaced: replacing it would invalidate the tier-1 ImageCache key
  // and the identity assertions the frozen navigation probes rest on.
  // The catch-up publish. PREFERS THE q70 PAYLOAD (spec R5): a promotion whose
  // payload is already a full-size JPEG costs no decode at all. Only a payload
  // that CANNOT serve full-res pixels (a window-resolution [PixelPayload]) or a
  // refused pre-check falls through to the file decode below, and that fall-
  // through is counted by [debugBandEntryFileDecodeCount].
  Future<void> _upgradeFullRes(
    PhotoItem item,
    SourcePayload payload,
    int distance,
    VoidCallback notifyLoaded,
  ) async {
    final id = item.id;
    // Claimed synchronously, before any await: the second concurrent caller
    // for the same id (inline chained upgrade vs. queued upgrade, S-1) is
    // turned away here instead of running a duplicate FFI decode. The other
    // caller's in-flight upgrade is what will publish.
    if (_upgradesInFlight.contains(id)) return;
    _upgradesInFlight.add(id);
    try {
      // R5. Inside the claim deliberately: a payload publish is a publish, and
      // the claim is what makes a concurrent second caller a no-op.
      if (publishFromPayload(id, payload, notifyLoaded, distance: distance)) {
        return;
      }
      // FILE FALLBACK from here down -- unchanged machinery (spec R5, R8).
      // Failed once for THIS payload: do not re-buy a 61-406ms decode on every
      // settle. The memo dies with the payload (design §2.5).
      if (_registry.hasFullResFailure(id, payload)) return;
      final decoder = _dngDecoder();
      final file = item.bestFileToLoad;
      // Orientation comes from the memo the probe already filled (invariant
      // I6): no bridge round trip is bought to rotate a frame.
      final orientation = _exifOrientationFor(id);
      if (decoder == null || file == null || orientation == null) {
        _registry.markFullResFailure(id, payload);
        return;
      }

      ui.Image image;
      try {
        debugBandEntryFileDecodeCount++;
        final decoded = await decoder(file.path);
        image = await decodedRgbaToImage(
          decoded,
          exifOrientation: orientation,
          gate: _compositeGate,
        );
      } catch (_) {
        // Tier-1 display is untouched and this is NOT a permanent miss: the
        // item has a payload and is on screen (design §2.5).
        _registry.markFullResFailure(id, payload);
        return;
      }

      // Re-checked after the await, per invariant I4: the window may have
      // moved or the payload been replaced while the decode ran, in which
      // case the image is released HERE rather than stored anywhere.
      if (!_windowIds.contains(id) ||
          !identical(_currentPayloadFor(id), payload)) {
        image.dispose();
        return;
      }
      // Contract deliverable 2: route the hand-off through the pacer instead
      // of calling `publishFullRes` directly. `exempt` mirrors the tier-1
      // rule ([isSelectedExempt]) -- the item the user is looking at must not
      // wait a frame for its own full-resolution pixels, the same rationale
      // the full-res band already applies to decode ORDER; this applies
      // it to publish TIMING too. [_publishOrDiscard] tracks the claim in
      // [_pendingFullResPublish] so a queued (not yet drained) publish still
      // blocks a redundant decode, and its `stillValid` re-checks at DRAIN
      // time (G-023 pattern): a paced entry may sit queued across a
      // navigation or a payload replacement, and a stale `ui.Image` must be
      // disposed, not cached.
      _publishOrDiscard(id, payload, distance, image, notifyLoaded, source: 'upgrade');
    } finally {
      _upgradesInFlight.remove(id);
    }
  }

  /// Publishes [id]'s tier-2 full-resolution entry BY DECODING ITS q70 PAYLOAD.
  /// The single route for first view and catch-up alike (spec R2).
  ///
  /// THE PRE-CHECKS LIVE HERE, not at the call sites, for the reason the
  /// deleted piggyback route recorded: a caller-side copy is a second place
  /// that has to remember the matching cleanup. Both callers (the controller's
  /// publish site and [_upgradeFullRes]'s payload arm) rely on that.
  ///
  /// Returns true when a publish was SUBMITTED to the pacer. False means this
  /// payload cannot serve a full-resolution entry (a [PixelPayload] -- the
  /// window-resolution fallback arm, which has no full-res pixels) or the
  /// pre-checks refused. A false allocates nothing and owns nothing, so no
  /// caller owes a dispose on it.
  ///
  /// NOT a `Future`: the submission is synchronous and the pixel decode happens
  /// later, inside `ImageCache`, when the `MemoryImage` resolves. Do not await.
  bool publishFromPayload(
    String id,
    SourcePayload payload,
    VoidCallback? notifyLoaded, {
    required int distance,
  }) {
    // Taken SYNCHRONOUSLY (invariant I4). `_hasFullResClaimFor` -- not merely
    // the registry -- so a publish this same sweep already paced (queued, not
    // yet landed) is not submitted twice.
    if (!_windowIds.contains(id) ||
        !identical(_currentPayloadFor(id), payload) ||
        _hasFullResClaimFor(id, payload)) {
      return false;
    }
    switch (payload) {
      case EncodedPayload():
        debugPayloadDecodePublishCount++;
        _publishEncodedOrDiscard(
          id,
          payload,
          distance,
          _fullSizeProviderForPayload(payload),
          notifyLoaded ?? () {},
        );
        return true;
      case PixelPayload():
        // A window-resolution payload has no full-resolution pixels to decode.
        // The caller's remaining option is the counted file fallback (T5); it
        // is NOT this route's job to buy a decode.
        return false;
    }
  }
}
