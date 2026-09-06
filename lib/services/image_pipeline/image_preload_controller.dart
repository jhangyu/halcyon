import 'dart:async';
import 'dart:math' as math;

import 'package:ceyx/ceyx.dart' show CeyxEncodeService;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../models/photo_item.dart';
import '../../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import 'dart_image_loader.dart' show resetSidebarWalkMemo;
import 'dng_decode_contract.dart';
import 'dng_decode_service.dart'
    show bumpHalcyonDecodePoolGeneration, setHalcyonDecodePoolWidth;
import 'idle_publish_scheduler.dart';
import 'image_source_types.dart';
import 'payload_claim.dart';
import 'payload_reencoder.dart';
import 'payload_state.dart';
import 'photo_payload.dart';
import 'photo_payload_cache.dart';
import 'photo_source.dart';
import 'prefetch_scheduler.dart';
import 'raw_full_res_image.dart';
import 'raw_pixels_image.dart';
import 'retention_policy.dart';
import 'sidebar_thumbnail_controller.dart';
import 'stage_widths.dart';
import 'decode_lane.dart';
import 'lane_priority.dart';
import 'encode_stage.dart';
import 'inflight_bytes_budget.dart';
import 'publication_pacer.dart';
import 'tier_two_registry.dart';
import 'tier_two_scheduler.dart';

/// Production binding for [PayloadEncoder] (user ruling 2026-08-30, after the
/// Task 0 STOP gate): pure-Dart `encodeJpegFromRgba` measured 4102ms median at
/// q80, 8x over the 500ms lane-budget gate. This calls ceyx's native
/// libjpeg-turbo encoder instead (in-process gate median 89ms). The pure-Dart
/// encoder is UNCHANGED and remains the sidebar codec's encoder and the
/// default test/seam binding -- only the controller's default wiring changes.
Future<Uint8List> _encodeJpegNative(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) {
  return CeyxEncodeService().encodeJpegNative(
    rgba,
    width: width,
    height: height,
    quality: quality,
  );
}

/// Shared tier-1 (window-resolution) provider factory. MUST be used by both
/// the display widget and the precache path with the SAME [bytes] object
/// identity and the SAME [width]/[height] — the resulting [ResizeImageKey]
/// is only equal (i.e. resolves as a cache hit instead of a silent second
/// decode) when all three match.
ImageProvider tierOneProviderFor(
  Uint8List bytes, {
  required int width,
  required int height,
}) {
  return ResizeImage(
    MemoryImage(bytes),
    width: width,
    height: height,
    policy: ResizeImagePolicy.fit,
  );
}

/// Shared tier-2 (full size, unresized) provider factory. Same rule as
/// [tierOneProviderFor]: display and precache MUST call this with the same
/// [bytes] object identity to land on the same ImageCache key.
ImageProvider fullSizeProviderFor(Uint8List bytes) => MemoryImage(bytes);

/// Navigation must be quiet for this long before tier-2 (full size) decode
/// starts, so continuous arrow-key navigation never triggers a burst of
/// expensive full-frame decodes for images the user only passed through.
const Duration tierTwoNavigationDebounce = Duration(milliseconds: 250);

/// How long a notifier survives after a view last asked for it, even once its
/// id has left the retention union.
///
/// Sized to the sidebar's scroll debounce: a row built during that window has
/// called `stateFor` but its id is not in the sidebar's wanted set yet (the set
/// is rewritten only inside the timer), so a navigation-side sweep in the same
/// window used to dispose a notifier a live row was already holding --
/// silently, since every later `_markStage` for a missing id early-returns.
/// Deliberately NOT the sidebar's own constant: this bounds NOTIFIER LIFETIME,
/// not scroll settling, and the two must be free to move apart.
///
/// The notifier map's bound therefore becomes "retention union + ids touched
/// within this grace", which is still finite: a deferred id is collected by the
/// NEXT sweep after its grace expires, and sweeps run from both contributors to
/// the union. No new timer is introduced -- a second lifetime authority is
/// exactly what this map does not need.
const Duration kPayloadStateDisposalGrace = Duration(milliseconds: 100);

/// Rows of sidebar thumbnails fetched (and kept cached) beyond each edge of
/// the visible range. See [ImagePreloadController.preloadThumbnails].
const int thumbnailPrefetchMargin = 20;

/// Long edge requested from [PhotoSource] before the view has reported its
/// real viewport size. Matches the native preview cap, so the first pass asks
/// for the same thing the native bridge would have produced anyway.
const int kDefaultPreviewLongEdge = 2800;

/// Orchestrates prefetch. It coordinates four collaborators and holds no
/// file-type knowledge of its own:
///
///   [PrefetchScheduler]  when, and on which rung  (the only cost-aware layer)
///   [PhotoPayloadCache]  what is kept             (type-blind, byteCost only)
///   [PhotoSource]        how bytes/pixels are produced (the only type-aware layer)
///   tier providers       how a payload becomes a decoded frame
///
/// Nothing here disposes an image. Every retained payload is a plain
/// `Uint8List`, so eviction is dropping a reference and a late arrival can
/// only cost bytes -- never a use-after-dispose. That is why the ~50MB
/// ownership contract, the in-flight set, the self-disposing late decode and
/// the 25-line warning about the debounce's second job are all gone (design §4,
/// invariants I5 and I7).
class ImagePreloadController {
  ImagePreloadController({
    required NativeImageLoad imageLoader,
    DngFullDecoder? dngDecoder,
    PayloadEncoder? payloadEncoder = _encodeJpegNative,
    RetentionPolicy retention = const RetentionPolicy.floor(),
    int decodeLaneWidth = 1,
    FrameHook? scheduleFrameCallback,
    int publicationsPerFrame = 1,
    int? inflightByteBudget,
    CompositeGate compositeGate = immediateCompositeGate,
    // Test-only seam (test-speedup campaign 2026-09-06): lets tests shrink
    // the production 250ms tier-2 quiet period instead of waiting it out in
    // real time. Production callers must not pass this.
    Duration navigationDebounce = tierTwoNavigationDebounce,
  }) : _navigationDebounce = navigationDebounce,
       _retention = retention,
       _inflight = InflightBytesBudget(
         maxBytes: inflightByteBudget ?? retention.payloadByteBudget ~/ 4,
       ),
       _frameHook = scheduleFrameCallback,
       _publicationsPerFrame = publicationsPerFrame,
       _compositeGate = compositeGate,
       _source = PhotoSource(
         loader: imageLoader,
         dngDecoder: dngDecoder,
         payloadEncoder: payloadEncoder,
         compositeGate: compositeGate,
       ),
       _stageWidths = StageWidths.derive(decodeLaneWidth),
       _decodeLane = DecodeLane(width: decodeLaneWidth),
       // Same derivation as `_stageWidths` above -- recomputed rather than
       // read off it because an initialiser list cannot read `this`. The
       // constructor body's `_applyStageWidths` re-pushes it anyway; building
       // it at the derived width just means it is never briefly wrong.
       _encodeStage = EncodeStage(
         width: StageWidths.derive(decodeLaneWidth).encode,
       ) {
    // Push the widths the stages were BUILT with, not just later changes:
    // until the stored preference hydrates and calls [setDecodeLaneWidth], the
    // lane and the pool would otherwise disagree (lane = this constructor's
    // value, pool = its own construction default), and any decode admitted in
    // that window is bounded by the wrong number.
    //
    // `pushSidebar: false` because [_sidebar] is `late final` and its closures
    // capture `this`: touching it here would force it into existence during
    // construction. It is born at the right width instead, from
    // `deriveQueueWidth: _stageWidths.derive` in its own initialiser.
    _applyStageWidths(_stageWidths, pushSidebar: false);
  }

  /// How far retention reaches and how many bytes it may hold. Sized from
  /// total physical memory at startup (see retention_policy.dart); the
  /// default is the shipped floor, so every test and every platform without
  /// a memory reading behaves exactly as before. Mutable through
  /// [setRetention] (the user's memory-tier setting), publicly read-only.
  RetentionPolicy _retention;
  RetentionPolicy get retention => _retention;

  /// See the constructor's test-only seam note; wired into [_tierTwoScheduler].
  final Duration _navigationDebounce;

  /// Re-tunes retention at runtime (the user's memory-tier setting).
  ///
  /// `before`/`after` need no push: every pass reads them fresh off
  /// [retention], so a widened window applies on the next navigation and a
  /// narrowed one on the next retention sweep. The byte budget DOES need a
  /// push, and shrinking it sweeps immediately -- see
  /// [PhotoPayloadCache.setByteBudget].
  void setRetention(RetentionPolicy policy) {
    if (policy == _retention) return;
    _retention = policy;
    _cache.setByteBudget(policy.payloadByteBudget);
    _inflight.maxBytes = policy.payloadByteBudget ~/ 4;
  }

  @visibleForTesting
  int get debugPayloadCacheByteBudget => _cache.byteBudget;

  final PhotoSource _source;

  /// `late final` for the same reason [_sidebar] is: the eviction callback is
  /// an instance method, so this cannot be built in the initialiser list.
  late final PhotoPayloadCache _cache = PhotoPayloadCache(
    byteBudget: _retention.payloadByteBudget,
    onEvicted: _onPayloadEvicted,
  );
  final PrefetchScheduler _scheduler = PrefetchScheduler();

  /// THE ONE lane every expensive (real RAW) decode runs on, shared by payload
  /// production here and by the tier-2 catch-up loads and full-resolution
  /// upgrades in [TierTwoScheduler]. Sharing it is what makes "at most [width]
  /// RAW decodes in flight" a property of the pipeline rather than of one
  /// scheduler (2026-08-26 ruling, width generalised 2026-08-30).
  final DecodeLane _decodeLane;

  /// Read through to the lane, never a shadow field: the controller and the
  /// lane can then never disagree (same reasoning as [AppState.retentionPolicy]).
  int get decodeLaneWidth => _decodeLane.width;

  /// Every stage width in this controller, derived from the one configured
  /// number. Read-through, never a shadow copy of the stages' own fields.
  StageWidths get stageWidths => _stageWidths;
  StageWidths _stageWidths;

  /// Live setting change from the settings page. Values below 1 clamp to 1,
  /// once, inside [StageWidths.derive]. There is no upper clamp here: the
  /// ceiling on the user's setting belongs to `AppState`, where the
  /// preference is read (lead ruling 2026-09-06, TC-966).
  ///
  /// P2: the number the user sets is the ONE input every stage width derives
  /// from -- lane, native pool, encode stage and the sidebar derive queue.
  /// The lane still owns near-to-far ORDER (the pool is FIFO and knows nothing
  /// about the selected index); the pool owns worker lifetime and the dylib.
  void setDecodeLaneWidth(int width) =>
      _applyStageWidths(StageWidths.derive(width));

  /// THE single write path for every stage width.
  ///
  /// The pool is pushed the value read back OFF THE LANE rather than the
  /// argument, so the "clamped exactly once, in the lane's setter" property
  /// the pool relied on before P2 is unchanged.
  ///
  /// There is deliberately NO equality guard: TC-938/TC-966
  /// (`decode_pool_wiring_test.dart`) pin push-on-EVERY-call as the pool's
  /// contract -- `pushed.last` after any `setDecodeLaneWidth` must be that
  /// call's clamped width, which a "skip the redundant push" short-circuit
  /// turns into a stale read (or, on the first call, no element at all).
  /// Suppressing pushes would also be a behaviour change at default widths,
  /// which P2 forbids. The two added pushes are idempotent setters, so
  /// pushing unconditionally costs nothing.
  ///
  /// [pushSidebar] exists only so the constructor's call does not force the
  /// `late final` [_sidebar] into existence.
  void _applyStageWidths(StageWidths widths, {bool pushSidebar = true}) {
    _stageWidths = widths;
    _decodeLane.width = widths.decodeLane;
    decodePoolWidthSink(_decodeLane.width);
    _encodeStage.width = widths.encode;
    if (pushSidebar) _sidebar.setDeriveQueueWidth(widths.derive);
  }

  @visibleForTesting
  int get debugEncodeStageWidth => _encodeStage.width;

  @visibleForTesting
  int get debugDeriveQueueWidth => _sidebar.deriveQueueWidth;

  /// Seam for the process-wide pool-width push. Overridable so a test can
  /// observe the push without constructing a real pool.
  @visibleForTesting
  static void Function(int width) decodePoolWidthSink =
      setHalcyonDecodePoolWidth;

  /// Seam for the folder-switch generation bump (soft cancellation). Same
  /// reason as [decodePoolWidthSink]: a test can observe the push without a
  /// real pool, and a controller under test never reaches into ceyx.
  @visibleForTesting
  static void Function() decodePoolGenerationSink =
      bumpHalcyonDecodePoolGeneration;

  /// Everything the sidebar thumbnail strip owns, extracted 2026-09-03. Built
  /// AD-028-style from supplier CLOSURES, never from the cache/source objects
  /// themselves, so retention policy keeps exactly one owner (this class) and
  /// the sidebar can never grow a second opinion about what is retained.
  ///
  /// `late final` because every closure below captures `this`.
  late final SidebarThumbnailController _sidebar = SidebarThumbnailController(
    peekPayload: _cache.peek,
    hasPayload: _cache.contains,
    isPreviewPermanentMiss: _permanentMisses.contains,
    decodeLane: _decodeLane,
    ensurePayload: (item) => _ensurePayload(
      item,
      distance: 0,
      notifyLoaded: null,
      onSerialLane: true,
    ),
    retentionIds: () => _retentionIds,
    republishEvictionPriority: _republishEvictionPriority,
    onTileLanded: _markThumbnailReady,
    deriveQueueWidth: _stageWidths.derive,
  );

  /// The JPEG re-encode's own bounded stage. Deliberately NOT the [DecodeLane]:
  /// the encode measured 89ms median and used to hold a decode slot for all of
  /// it, so lane throughput was decode + encode rather than decode alone. The
  /// lane's key-dedup, priority replacement and near-to-far ordering exist to
  /// schedule DECODES; an encode has neither a key space nor a distance.
  final EncodeStage _encodeStage;

  @visibleForTesting
  int get debugEncodeStageRunningCount => _encodeStage.runningCount;

  /// Decodes currently OCCUPYING a lane slot. Exposed so a test can establish
  /// "the lane is busy" as a precondition instead of assuming it: an entry the
  /// lane has already started is not pending, so an assertion about pending
  /// ranks is only meaningful once the slots are known to be full.
  @visibleForTesting
  int get debugDecodeLaneRunningCount => _decodeLane.runningCount;

  final FrameHook? _frameHook;
  final int _publicationsPerFrame;

  /// Owns every tier-1 ImageCache registration's TIMING. The pipeline had no
  /// notion of a frame budget anywhere: [_precacheTierOneWindow] walked the
  /// whole retention window in one synchronous loop on every navigation pass,
  /// so codec-completion work arrived as one clump behind one navigation
  /// event. The selected item stays exempt, so first-paint latency for the
  /// photo the user is looking at is unchanged.
  ///
  /// `late final` rather than an initialiser-list entry: the `isSelected`
  /// predicate reads [_selectedId], and an initialiser list cannot touch
  /// `this` (same reason [_tierTwo] is lazy).
  late final PublicationPacer _pacer = PublicationPacer(
    scheduleFrameCallback: _frameHook,
    perFrame: _publicationsPerFrame,
    // SIZED FROM THE WINDOW, not left at the unit's default of 4. One
    // navigation pass submits a registration for EVERY retained slot, and the
    // pacer's overflow rule drops the highest-rank entry outright -- with a
    // queue of 4 the far half of the window would never receive a tier-1
    // entry at all. Pacing is about WHEN a registration lands, never about
    // whether it lands.
    maxQueued: _retention.before + _retention.after + 1,
    // Deliverable 3: only the selected item may publish synchronously, and
    // that is now the pacer's rule rather than the call site's promise.
    isSelected: (id) => id == _selectedId,
  );

  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  bool get debugPacerHasFrameHook => _pacer.debugHasFrameHook;

  /// The pacing seam handed to every UI-isolate compositing step (contract
  /// deliverable 2). Held as a field only so [debugCompositeGateIsPaced] can
  /// answer "is production actually paced" without reaching into privates.
  final CompositeGate _compositeGate;

  @visibleForTesting
  bool get debugCompositeGateIsPaced =>
      !identical(_compositeGate, immediateCompositeGate);

  /// Bounds the TRANSIENT full-frame buffers the stage split puts in flight --
  /// the decoded RGBA, the oriented full-res RGBA and the encoder's input.
  ///
  /// [RetentionPolicy.payloadByteBudget] does NOT cover these: it counts
  /// RETAINED payloads (`photo_payload_cache.dart`), and every buffer here is
  /// in flight and invisible to it. A per-stage TASK COUNT is not a memory
  /// bound either, because per-item buffers vary by 5x across a mixed folder.
  ///
  /// The default is a quarter of the payload budget -- derived from an
  /// existing, RAM-tiered number rather than a new magic constant.
  final InflightBytesBudget _inflight;

  @visibleForTesting
  int get debugInflightBytes => _inflight.inFlightBytes;

  @visibleForTesting
  Set<String> get debugThumbPermanentMisses => _sidebar.permanentMisses;

  @visibleForTesting
  Set<String> get debugSidebarEnqueuedIds => _sidebar.enqueuedIds;

  /// The lane priority [id]'s payload task is currently queued at, or null.
  /// Exposed so G-027's demotion hazard is asserted directly (TC-436).
  @visibleForTesting
  int? debugLanePendingPriorityFor(String id) =>
      _decodeLane.pendingPriorityOf((LaneTaskKind.payload, id));

  /// Count of content-probe (file IO) calls launched by [_probeWindowItem],
  /// i.e. once per window slot per navigation pass that reaches the probe
  /// (fast-path resolutions in [_earlyResolve] do not count). Phase 6's real
  /// saving -- one probe chain per window slot per superseded event never
  /// launched at all -- has no seam that discriminates it at the lane layer
  /// (parking-lot item 3, docs/logs/2026-09-06/phase5-6-baton-for-next-worker.md
  /// §6): the lane's post-burst state is identical with or without
  /// coalescing, so this counter is the only observable that can tell the two
  /// apart. Zero behavior change: read-only, incremented alongside the
  /// existing probe call.
  @visibleForTesting
  int debugProbeInvocationCount = 0;

  /// Count of tier-2 catch-up re-enqueues issued so far (see
  /// [TierTwoScheduler.debugCatchUpEnqueueCount]). Proves the sweep actually
  /// fired at least once, which TC-984's merged-order assertions cannot: they
  /// would pass identically if the sweep never ran and navigation alone
  /// produced the ruled order.
  @visibleForTesting
  int get debugCatchUpEnqueueCount =>
      _tierTwoScheduler.debugCatchUpEnqueueCount;

  /// Detail-path (tier-1/tier-2) production claims, keyed by BARE photo id.
  ///
  /// Same membership at every instant as the bare `Set<String>` of in-flight
  /// ids it replaces; the addition is an owner tag and an assertion at each
  /// hand-off. Thumbnail loads live in the sidebar's own set and deliberately
  /// do not appear here.
  final PayloadClaimRegistry _claims = PayloadClaimRegistry();

  // ---------------------------------------------------------------------------
  // PHASE 5 -- per-item payload state.
  //
  // One [PayloadStateNotifier] per id a view has asked about, NEVER one per id
  // in the folder: entries are created on demand by [stateFor] and disposed by
  // the retention sweep ([_sweepPayloadStates]), so the map's size is bounded
  // by the retention union rather than by the folder (plan risk R7).
  //
  // This is a NOTIFICATION channel, not a second source of truth: every write
  // below sits at a site that already had a landing (`_cache.put`, the
  // permanent-miss latch, the claim). [_derivedStateFor] recomputes the value
  // from the same containers, so a notifier created after the fact can never
  // disagree with the cache.
  // ---------------------------------------------------------------------------
  final Map<String, PayloadStateNotifier> _payloadStates = {};

  // Every notifier this controller has disposed, ever. The acceptance
  // condition "every notifier removed from the map has had dispose() called"
  // is asserted as `disposeCount == removals`, which needs a sink that
  // survives the removal.
  int _payloadStateDisposeCount = 0;

  /// When each id was last handed to a view through [stateFor]. Entries are
  /// dropped with their notifier, so this map is bounded by [_payloadStates].
  final Map<String, DateTime> _payloadStateTouchedAt = {};

  int _payloadStateDeferredCount = 0;

  /// How many notifiers the last sweep kept alive purely because of
  /// [kPayloadStateDisposalGrace].
  @visibleForTesting
  int get debugPayloadStateDeferredCount => _payloadStateDeferredCount;

  /// Seam for the grace period's clock, same shape as [decodePoolWidthSink]:
  /// a test can advance time without a faked engine clock (FakeAsync plus a
  /// real engine future hangs forever, so it is not an option here).
  /// Production code never assigns it.
  @visibleForTesting
  static DateTime Function() payloadStateClock = DateTime.now;

  /// [id]'s payload readiness, for a view to listen to instead of rebuilding
  /// on the app-wide notification.
  ///
  /// Created on demand and re-created after eviction, so a caller that keeps
  /// listening across a retention sweep sees a disposed (silent) notifier and
  /// the NEXT read returns a fresh one at [PayloadStage.absent] -- never a
  /// throw. Views receive STATE only; providers are still built exclusively by
  /// this class's two factories (plan risk R1).
  ValueListenable<PayloadState> stateFor(String id) => _notifierFor(id);

  PayloadStateNotifier _notifierFor(String id) {
    // Stamped on every call, creation and re-read alike: a re-read is equally
    // the signal that a live view is holding this id.
    _payloadStateTouchedAt[id] = payloadStateClock();
    return _payloadStates.putIfAbsent(
      id,
      () => PayloadStateNotifier(_derivedStateFor(id)),
    );
  }

  /// The truth as of right now, read off the same containers the getters use.
  /// A notifier is born with this rather than with `absent` so a widget that
  /// starts listening to an item that landed BEFORE it was built paints the
  /// photo instead of a spinner.
  PayloadState _derivedStateFor(String id) {
    final thumbnailReady = _sidebar.thumbnailPayloadFor(id) != null;
    if (_permanentMisses.contains(id)) {
      return PayloadState(
        stage: PayloadStage.failed,
        thumbnailReady: thumbnailReady,
      );
    }
    if (_cache.contains(id)) {
      return PayloadState(
        stage: _tierTwo.isReady(id)
            ? PayloadStage.tierTwoReady
            : PayloadStage.tierOneReady,
        thumbnailReady: thumbnailReady,
      );
    }
    if (_claims.isHeld(id)) {
      return PayloadState(
        stage: PayloadStage.decoding,
        thumbnailReady: thumbnailReady,
      );
    }
    return PayloadState(
      stage: PayloadStage.absent,
      thumbnailReady: thumbnailReady,
    );
  }

  /// Moves [id] FORWARD to [stage]. Never backwards, and never out of
  /// [PayloadStage.failed] -- only [reset] (which disposes every notifier)
  /// clears that. A no-op when no view has asked about [id]: the state is
  /// derived on first [stateFor] anyway, so materialising a notifier here
  /// would grow the map for items nobody is watching.
  void _markStage(String id, PayloadStage stage) {
    final notifier = _payloadStates[id];
    if (notifier == null) return;
    final current = notifier.value;
    if (current.stage == PayloadStage.failed) return;
    if (stage != PayloadStage.failed && stage.index <= current.stage.index) {
      return;
    }
    notifier.trySetValue(current.copyWith(stage: stage));
  }

  /// The ONE place a stage may move BACKWARDS.
  ///
  /// [PhotoPayloadCache] evicts under byte pressure without asking whether the
  /// id is still retained, so an item inside the window can lose its payload
  /// while a view is watching it. [_markStage] is forward-only by design (a
  /// landing must never be un-landed by a late arrival), which is why the
  /// demotion cannot go through it: instead this recomputes the item's state
  /// from the same containers a notifier born right now would read, so the
  /// observable state stays a FUNCTION of the containers rather than a second
  /// opinion. A permanently-missing item is untouched -- `failed` is terminal
  /// until `reset()`, which [_derivedStateFor] already encodes.
  ///
  /// Runs synchronously inside `_cache.put`, i.e. inside a landing: it touches
  /// [_payloadStates] only and never calls back into the cache's mutating API.
  void _onPayloadEvicted(String id) {
    final notifier = _payloadStates[id];
    if (notifier == null) return;
    notifier.trySetValue(_derivedStateFor(id));
  }

  /// The sidebar wrote a derived tile for [id]. A separate axis from the stage
  /// ladder -- see [PayloadState.thumbnailReady].
  void _markThumbnailReady(String id) {
    final notifier = _payloadStates[id];
    if (notifier == null) return;
    notifier.trySetValue(notifier.value.copyWith(thumbnailReady: true));
  }

  /// Promotes every watched id whose tier-2 entry has become resident.
  ///
  /// A sweep rather than a per-id call because the tier-2 landing callbacks
  /// live in [TierTwoScheduler], which carries ONE callback for the whole
  /// window and does not name the id it just published. The readiness answer
  /// itself is still [TierTwoRegistry]'s ([isFullSizeReady]) -- this reads it,
  /// it does not re-derive it. Bounded by the notifier map, i.e. by the
  /// retention union.
  void _refreshTierTwoStates() {
    if (_payloadStates.isEmpty) return;
    for (final id in _payloadStates.keys) {
      if (_tierTwo.isReady(id)) _markStage(id, PayloadStage.tierTwoReady);
    }
  }

  /// Wraps a landing callback so tier-2 publications reach the per-item
  /// notifiers as well. Calls [notify] exactly once, so notification
  /// cardinality (pin B3) is unchanged.
  VoidCallback _withTierTwoStates(VoidCallback notify) {
    return () {
      _refreshTierTwoStates();
      notify();
    };
  }

  /// Disposes and drops every notifier whose id has left the retention union.
  ///
  /// THE lifetime rule (plan risk R7): notifiers are disposed here and nowhere
  /// else on the steady-state path, so a widget listening to an id inside the
  /// union can never meet a disposed notifier. Called from
  /// [_republishEvictionPriority], which both contributors to the union (the
  /// navigation pass and the sidebar sweep) already call whenever their half
  /// changes.
  void _sweepPayloadStates() {
    if (_payloadStates.isEmpty) return;
    final keep = _retentionIds;
    final now = payloadStateClock();
    _payloadStateDeferredCount = 0;
    _payloadStates.removeWhere((id, notifier) {
      if (keep.contains(id)) return false;
      // A row that asked for this state moments ago is live even though the
      // sidebar's wanted set has not caught up yet (the set is rewritten only
      // inside its 100ms debounce). Disposing here is the orphan bug; the NEXT
      // sweep after the grace expires collects it, and sweeps run from both
      // contributors to the union, so nothing is kept indefinitely.
      final touchedAt = _payloadStateTouchedAt[id];
      if (touchedAt != null &&
          now.difference(touchedAt) < kPayloadStateDisposalGrace) {
        _payloadStateDeferredCount++;
        return false;
      }
      notifier.dispose();
      _payloadStateDisposeCount++;
      _payloadStateTouchedAt.remove(id);
      return true;
    });
  }

  void _disposeAllPayloadStates() {
    for (final notifier in _payloadStates.values) {
      notifier.dispose();
      _payloadStateDisposeCount++;
    }
    _payloadStates.clear();
    // A folder reload destroys everything: the grace period does not apply.
    _payloadStateTouchedAt.clear();
    _payloadStateDeferredCount = 0;
  }

  /// Live per-item notifiers. The no-leak acceptance condition asserts this
  /// against the retention union plus the sidebar's wanted set.
  @visibleForTesting
  int get debugPayloadStateCount => _payloadStates.length;

  /// Total notifiers disposed by this controller (the dispose-count sink).
  @visibleForTesting
  int get debugPayloadStateDisposeCount => _payloadStateDisposeCount;

  @visibleForTesting
  PayloadState debugPayloadStateFor(String id) => _notifierFor(id).value;

  // Callbacks from callers who selected an item while its load was already in
  // flight (started by a previous preload pass). Flushed once the in-flight
  // load completes so the UI never strands on a permanent spinner.
  final Map<String, List<VoidCallback>> _pendingPreviewNotifies = {};

  // The navigation demand: the current -3..+5 window. Async source completions
  // re-check membership before writing, so a late arrival cannot resurrect an
  // item the user has already navigated away from.
  Set<String> _navRetentionIds = {};

  // The union of the navigation demand and the SIDEBAR's demand
  // ([SidebarThumbnailController.wantedIds] -- the visible range +/-
  // thumbnailPrefetchMargin).
  //
  // USER RULING 2026-08-30 (contract D5, "捲動亦填充 payload"): scrolling fills
  // the payload cache too, so the sidebar is a second contributor to WHAT IS
  // RETAINED. It is deliberately NOT a second budget or a second eviction
  // rule -- D4's "one retention rule for every file type" is untouched; only
  // the membership question gained a contributor.
  //
  // A getter, not a third stored set, so the two contributors can never
  // disagree with what the cache is actually asked to retain.
  Set<String> get _retentionIds => _navRetentionIds.union(_sidebar.wantedIds);

  @visibleForTesting
  Set<String> get debugRetentionIds => _retentionIds;

  // Near-to-far eviction order, kept split by contributor for the same reason
  // the sets are: republished whenever either changes.
  List<String> _navPriorityIds = [];

  @visibleForTesting
  List<String> get debugEvictionPriority => _evictionPriorityOrder();

  /// Navigation ids near-to-far FIRST, then sidebar-only ids by distance from
  /// the viewport's first visible row.
  ///
  /// `PhotoPayloadCache._pickVictim` evicts from the FAR end, so a
  /// whole-folder scroll evicts its own oldest, farthest tiles long before it
  /// touches anything near the selection -- which is what makes "scrolling
  /// fills the cache" safe against the -3..+N guarantee.
  List<String> _evictionPriorityOrder() {
    final seen = <String>{};
    final order = <String>[];
    for (final id in _navPriorityIds) {
      if (seen.add(id)) order.add(id);
    }
    for (final id in _sidebar.priorityIds) {
      if (seen.add(id)) order.add(id);
    }
    return order;
  }

  void _republishEvictionPriority() {
    _cache.setEvictionPriority(_evictionPriorityOrder());
    // PHASE 5: the union just changed, and this is the ONE place both of its
    // contributors report a change from. Notifier lifetime is therefore tied
    // to exactly the set this line publishes, not to a second opinion about
    // what is retained.
    _sweepPayloadStates();
  }

  // Tier-1 (window-resolution) decode precache bookkeeping.
  int? _tierOneWidth;
  int? _tierOneHeight;
  final Map<String, Object> _tierOneKeys = {};

  // Tier-2 (full size) decode precache. Own window (+/-2), own key namespace
  // (distinct from tier-1's ResizeImageKey) and own eviction, so the two tiers
  // coexist without either clobbering the other's ImageCache entry for the
  // same item id.
  //
  // All tier-2 bookkeeping -- which id holds an entry, for which payload
  // object, has its decode finished, did its upgrade already fail -- lives in
  // [TierTwoRegistry]; all tier-2 SCHEDULING -- the +/-2 window, the 250ms
  // navigation debounce, the sequential decode queue, the full-res upgrade and
  // the piggyback publish -- lives in [TierTwoScheduler]. They are two units
  // and not one: the readiness conjunction was extracted away from scheduling
  // state on purpose (AD-027) and must not be re-joined to it.
  //
  // `_cache` and `_source` are final and initialised in the initialiser list,
  // so binding `peek` as a tear-off and reading `_source.dngDecoder` from these
  // field initialisers is safe.
  late final TierTwoRegistry _tierTwo = TierTwoRegistry(
    currentPayloadFor: _cache.peek,
  );
  late final TierTwoScheduler _tierTwoScheduler = TierTwoScheduler(
    registry: _tierTwo,
    lane: _decodeLane,
    currentPayloadFor: _cache.peek,
    fullSizeProviderFor: _fullSizeProviderForPayload,
    ensurePayload: _ensurePayload,
    dngDecoder: () => _source.dngDecoder,
    exifOrientationFor: (id) => _exifOrientations[id],
    navigationDebounce: _navigationDebounce,
    compositeGate: _compositeGate,
    // Contract deliverable 2: tier-2 full-resolution publishes now go
    // through the SAME pacer instance as tier-1 registrations, not a second
    // pacing mechanism. `PublicationPacer.submit`'s signature is exactly
    // `TierTwoScheduler`'s `PublishPacer` shape, so this is the pacer's own
    // method, not a wrapper.
    publishPacer: _pacer.submit,
  );

  // Items no source could produce anything for (corrupt/truncated/unsupported,
  // or a RAW decode failure whose legacy fallback also failed). Without this
  // the view cannot tell "not loaded yet" from "will never load" and spins
  // forever; it also stops every pass re-asking for an answer that cannot
  // change. Cleared only by [reset] (i.e. a folder reload).
  //
  final Set<String> _permanentMisses = {};

  // D3 subset of [_permanentMisses]: the specific reason was "no native RAW
  // decoder on this platform", not a genuine decode/read failure. See
  // [isNoNativeDecoder].
  final Set<String> _noNativeDecoderMisses = {};

  // id -> EXIF orientation, written by the content probe (and, only for files
  // the probe could not measure, by the bridge's rung-2 answer).
  //
  // This is what lets a serial-lane task hand `loadExpensive` an orientation
  // without a single further bridge or loader call: the same walk that decided
  // the lane already read IFD0 (invariant I6). Like the cost memo
  // it lives for the whole folder -- an item evicted from the retention window
  // and navigated back to must not have to buy its orientation twice -- so it
  // is cleared only by [reset].
  final Map<String, int> _exifOrientations = {};

  // The PREVIEW path's own generation, bumped by every [preloadImages] call
  // and by [reset]. It is deliberately separate from the sidebar's own batch
  // generation, which counts sidebar batches: a running preview pass awaits its priority
  // load and then its whole window, and by the time it resumes the user may
  // have navigated on or reloaded the folder -- at which point everything it
  // was about to do (the tier-1 precache, and above all rescheduling the
  // tier-2 debounce timer) belongs to a window that no longer exists.
  // Re-checked after every await, per invariant I4.
  int _previewGeneration = 0;

  /// Which FOLDER the currently-wanted work belongs to. Bumped ONLY by
  /// [reset] and [dispose].
  ///
  /// Deliberately NOT [_previewGeneration], which counts navigation passes and
  /// is bumped on every window walk (`++_previewGeneration` in the preview
  /// pass): gating payload completion on that counter would discard every load
  /// started before the user's next arrow key, i.e. almost all of them. A
  /// folder switch is the only event that makes an in-flight payload's whole
  /// bookkeeping — cost memo, cache write, permanent-miss latch — belong to
  /// state that no longer exists.
  ///
  /// Why it must exist at all: no FFI decode is cancellable, so [reset] cannot
  /// stop an in-flight expensive load; it can only clear the maps the load is
  /// about to write into. Without this gate, a decode started for the OLD
  /// folder lands after `reset()` has cleared `_permanentMisses` and writes
  /// into the NEW folder's state. Because [PhotoItem.id] is a user-controlled
  /// FILENAME (the collision class documented in decode_lane.dart), a
  /// same-named file in the new folder would be latched "unreadable for this
  /// session" by a failure that had nothing to do with it.
  int _folderGeneration = 0;

  int get _longEdge {
    final width = _tierOneWidth;
    final height = _tierOneHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return kDefaultPreviewLongEdge;
    }
    return math.max(width, height);
  }

  /// The retained payload for [id], whatever kind it is. The view's single
  /// "is there something to paint" question (design §3.5).
  ///
  /// Test-only visibility marker: production code reads payloads through the
  /// provider getters below, not this. Kept public (no `@visibleForTesting`
  /// enforcement failure) because 14 test call sites use it directly.
  @visibleForTesting
  SourcePayload? payloadFor(String? id) => _cache.peek(id);

  /// Whether the DETAIL path currently has [id] in flight. Thumbnail loads
  /// live in a separate set and deliberately do not answer true here.
  @visibleForTesting
  bool isLoadingForTest(String id) => _claims.isHeld(id);

  /// Encoded bytes for [id], or null when the item is not byte-backed (a RAW
  /// item retains pixels instead) or nothing is retained.
  Uint8List? imageBytesFor(String? id) {
    final payload = _cache.peek(id);
    return payload is EncodedPayload ? payload.bytes : null;
  }

  /// The provider for a pixel-backed item, or null if [id] is not one.
  ///
  /// Replaces the old decoded-provider accessor 1-for-1. The provider no
  /// longer has to be owned and handed out by this class: its key is the
  /// retained buffer's identity, so building a new one at the display site lands on exactly the
  /// same ImageCache entry (invariant I1).
  RawPixelsImage? pixelsProviderFor(String? id) {
    final payload = _cache.peek(id);
    return payload is PixelPayload ? RawPixelsImage(payload) : null;
  }

  /// The full-resolution tier-2 provider for [id], for EITHER tier-2 family
  /// (pixel-backed [RawFullResImage] or encoded-payload `MemoryImage`), or
  /// null when there is no resident full-resolution entry for the item's
  /// current payload.
  ///
  /// Unlike [pixelsProviderFor], this must NOT be rebuilt at the display site:
  /// every tier-2 key IS its own provider, so the object handed out here is
  /// the very object the controller registered as the ImageCache key.
  /// Resolving it while [isFullSizeReady] is true is a plain cache hit --
  /// `loadImage` is never reached, so [RawFullResImage]'s one-shot nature is
  /// never exercised on the display path (design §2.3).
  ImageProvider? fullResProviderFor(String? id) =>
      id == null ? null : _tierTwo.fullResProviderFor(id);

  /// The ids that currently hold a tier-2 ImageCache entry, both payload kinds.
  /// The dual-window property under test is exactly "this set == the +/-2 band"
  /// (AC-M5-2).
  @visibleForTesting
  Set<String> get debugTierTwoKeyIds => _tierTwo.keyIds;

  /// The tier-2 provider currently registered for [id] -- a [RawFullResImage]
  /// for a pixel-backed item, the encoded path's own provider otherwise --
  /// or null when the item has no tier-2 entry.
  ///
  /// Every tier-2 key in this class IS its own provider (`obtainKey` returns
  /// `this` for the pixel kind, and `MemoryImage` is its own key for the
  /// encoded kind), so this is a read of the existing bookkeeping and not a
  /// second registry. Tests use it to read [RawFullResImage.width]/[height]
  /// off the provider instead of resolving the image (AC-M5-3).
  @visibleForTesting
  ImageProvider<Object>? debugTierTwoProviderFor(String id) =>
      _tierTwo.providerFor(id);

  /// Ids currently holding a TIER-1 `ImageCache` key. The tier-2 twin of this
  /// is [debugTierTwoKeyIds]. Exposed so the retention tests can assert that
  /// sidebar-only ids get NEITHER tier's entry: that budget is sized for five
  /// full-size entries, not for a folder.
  @visibleForTesting
  Set<String> get debugTierOneKeyIds => _tierOneKeys.keys.toSet();

  SourcePayload? thumbnailPayloadFor(String id) =>
      _sidebar.thumbnailPayloadFor(id);

  @visibleForTesting
  int get debugThumbnailCacheLength => _sidebar.cacheLength;

  /// Sum of `byteCost` over the sidebar cache. Exists so INV-MEM is an
  /// asserted acceptance condition (TC-374) rather than an estimate in prose.
  @visibleForTesting
  int get debugThumbnailCacheByteCost => _sidebar.cacheByteCost;

  /// Total retained payload cost. The successor to the old "is that ~50MB
  /// handle disposed?" question: what bounds memory now is the sum over the
  /// retention window, not a hand-managed lifetime.
  @visibleForTesting
  int get retainedByteCost => _cache.totalByteCost;

  /// The ids currently retained, in least-recently-used order.
  @visibleForTesting
  Iterable<String> get retainedIds => _cache.ids;

  /// True when [id] could not be produced by any source and never will be in
  /// this session. The view shows an error instead of a spinner.
  bool hasFailed(String? id) => id != null && _permanentMisses.contains(id);

  /// D3 (docs/logs/2026-08-26/raw-support-contract.md): true when [id]'s
  /// permanent miss is specifically "this platform has no native RAW
  /// decoder", distinct from every other permanent-miss cause (a genuinely
  /// unreadable file, a throwing decoder, or a D2 browse-only RAW with no
  /// embedded preview). See [_ensurePayload]'s disambiguation comment for why
  /// this is decidable without [PhotoSource] carrying an extra field: with no
  /// decoder configured, the decoder-throws arm can never run, so this
  /// specific outcome shape is unambiguous. A view MAY use this to show
  /// "cannot decode on this platform" instead of a generic error; it is
  /// always a subset of [hasFailed].
  bool isNoNativeDecoder(String? id) =>
      id != null && _noNativeDecoderMisses.contains(id);

  /// The [kNoNativeDecoderCode] failure code for [id] when
  /// [isNoNativeDecoder] is true, else null. Exists so a caller does not have
  /// to hand-carry the string constant itself.
  String? noNativeDecoderCodeFor(String? id) =>
      isNoNativeDecoder(id) ? kNoNativeDecoderCode : null;

  /// Whether the full-size (tier-2) decode for [id] has COMPLETED and the
  /// resulting ImageCache entry is still resident for the item's CURRENT
  /// payload. The four-term conjunction (round-2 BLOCKER 1 + BLOCKER 3) now
  /// lives in exactly one place -- see [TierTwoRegistry.isReady].
  bool isFullSizeReady(String id) => _tierTwo.isReady(id);

  void reset() {
    // PHASE 6: a queued pass belongs to the folder being left. Dropping the
    // record is the cancellation -- the scheduled microtask still runs and
    // finds nothing, which is cheaper and less error-prone than trying to
    // unschedule it.
    _pendingIntent = null;
    _cache.clear();
    // PHASE 5: a folder reload is the ONLY thing that clears a `failed`
    // state, and it clears it by ending the notifier's life -- the next
    // [stateFor] builds a fresh one from the (now empty) containers.
    _disposeAllPayloadStates();
    _sidebar.reset();
    _claims.clear();
    _pendingPreviewNotifies.clear();
    _navRetentionIds = {};
    _navPriorityIds = [];
    _evictTierOneKeys();
    _decodeLane.clearPending();
    _encodeStage.clear();
    _pacer.clear();
    _inflight.clear();
    _tierTwoScheduler.cancelDebounce();
    _tierTwo.clear();
    _scheduler.reset();
    // W4b: the sidebar walk memo is keyed by path and must not survive a
    // folder switch, same lifetime as the prefetch memo reset above.
    resetSidebarWalkMemo();
    _permanentMisses.clear();
    _noNativeDecoderMisses.clear();
    _exifOrientations.clear();
    _previewGeneration++;
    // A folder switch supersedes every in-flight load. Two halves, and both
    // are needed: the pool stops DELIVERING old-folder decode results (soft
    // cancellation -- the only cancellation there is), and the folder gate in
    // [_completeOutcome] refuses whatever still lands from producers the pool
    // does not own. Order matters only in that both happen before the first
    // new-folder load is admitted, which they do: this is synchronous.
    _folderGeneration++;
    decodePoolGenerationSink();
  }

  /// Called by the view whenever the viewport's decode target size is known
  /// (window logical size x devicePixelRatio). Used for the tier-1 precache and
  /// as the long edge asked of [PhotoSource]; the display path computes and
  /// passes the same size directly to [tierOneProviderFor] itself, so there is
  /// a single source of truth per frame and no risk of the two diverging.
  void updateTargetSize(int width, int height) {
    _tierOneWidth = width;
    _tierOneHeight = height;
  }

  void dispose() {
    // Same reason as [reset]: an unawaited in-flight load must not write into
    // the maps cleared below.
    _folderGeneration++;
    _pendingIntent = null;
    _disposeAllPayloadStates();
    _sidebar.dispose();
    _decodeLane.clearPending();
    _encodeStage.clear();
    _pacer.clear();
    _inflight.clear();
    _tierTwoScheduler.cancelDebounce();
    _evictTierOneKeys();
    _tierTwo.clear();
    _navRetentionIds = {};
    _navPriorityIds = [];
    _cache.clear();
    // Nothing else to do: no image is owned here. A source still in flight at
    // teardown resolves into a payload nobody reads and is collected -- it
    // cannot leak a ~50MB handle, because there is no handle.
  }

  /// Evicts every recorded tier-1 [ImageCache] entry, then drops the keys.
  ///
  /// Called from BOTH [reset] and [dispose]. It exists as one helper rather
  /// than two copies because the defect it fixes WAS the drift: [dispose] had
  /// the evict loop and [reset] -- the folder-switch path -- had only the
  /// `clear()`, which orphaned a whole retention window of window-resolution
  /// entries per folder switch. Once the map is cleared, nothing can evict
  /// those entries by key ever again (the stale sweep and [dispose] both walk
  /// this same map), so byte-LRU pressure was their only remaining exit.
  ///
  /// `evict` already defaults to `includeLive: true`, so no argument is passed
  /// here: adding one would be a no-op.
  void _evictTierOneKeys() {
    for (final key in _tierOneKeys.values) {
      PaintingBinding.instance.imageCache.evict(key);
    }
    _tierOneKeys.clear();
  }

  // ---------------------------------------------------------------------------
  // PHASE 6 -- intent coalescing at the scheduler entrance.
  //
  // Nine arrow-key events used to buy nine full window passes: nine retention
  // recomputations, nine eviction republishes, nine sidebar sweeps, and nine
  // sets of per-slot chains for windows that were already history before their
  // probes came back. The events are not independent -- each one SUPERSEDES the
  // last -- so what the pipeline needs from a burst is the FINAL intent, once.
  //
  // The entrance therefore records intent and schedules one pass on a
  // microtask. It is deliberately a microtask and not a timer: no wall-clock
  // delay is introduced anywhere, so this is upstream of (and invisible to)
  // both existing debounces -- tier-2's 250ms and the sidebar's 100ms are
  // untouched, which G-001 and the tier-2 tests still pin.
  //
  // Why this is safe for callers that `await` the entrance: the pass microtask
  // is queued BEFORE the continuation of the returned future, so
  // `await preloadImages(...)` still resumes with the pass already issued --
  // exactly the Phase 3 contract ("returns when work has been ISSUED").
  // ---------------------------------------------------------------------------

  /// The one mutable intent, overwritten by every entrance call and consumed by
  /// the scheduled pass. Null between passes.
  _PendingIntent? _pendingIntent;
  bool _intentPassScheduled = false;
  int _intentPassCount = 0;

  /// Scheduling passes actually run. The nine-selections-one-pass property is
  /// asserted on this (plan §3 Phase 6 acceptance bullet 1).
  @visibleForTesting
  int get debugSchedulingPassCount => _intentPassCount;

  /// True while a burst's pass is queued but has not run yet.
  @visibleForTesting
  bool get debugHasPendingIntent => _pendingIntent != null;

  void _scheduleIntentPass() {
    if (_intentPassScheduled) return;
    _intentPassScheduled = true;
    scheduleMicrotask(_runIntentPass);
  }

  void _runIntentPass() {
    _intentPassScheduled = false;
    final intent = _pendingIntent;
    _pendingIntent = null;
    if (intent == null) return; // reset()/dispose() dropped it.
    _intentPassCount++;
    // NAVIGATION FIRST, then the sidebar. Not cosmetic: the sidebar's
    // re-enqueue guard reads the lane's pending priority for a key
    // (`isSidebarPriority`, G-027), so issuing the window before the sweep
    // means the sweep sees navigation's priorities rather than racing them.
    final navItems = intent.navItems;
    final selectedItemId = intent.selectedItemId;
    if (navItems != null && selectedItemId != null) {
      _issueNavigationPass(
        items: navItems,
        selectedItemId: selectedItemId,
        notifyLoaded: intent.notifyLoaded ?? () {},
      );
    }
    final thumbItems = intent.thumbItems;
    final startIdx = intent.thumbStartIdx;
    final endIdx = intent.thumbEndIdx;
    if (thumbItems != null && startIdx != null && endIdx != null) {
      // Unawaited by design: the sidebar's own contract is "the sweep has been
      // SCHEDULED", and its 100ms debounce owns the rest.
      unawaited(
        _sidebar.preloadThumbnails(
          items: thumbItems,
          startIdx: startIdx,
          endIdx: endIdx,
        ),
      );
    }
  }

  /// Records the navigation intent. A burst of calls in one turn of the event
  /// loop produces ONE pass, for the LAST selection -- see [_runIntentPass].
  Future<void> preloadImages({
    required List<PhotoItem> items,
    required String selectedItemId,
    VoidCallback? notifyLoaded,
  }) async {
    if (items.isEmpty) return;
    final intent = _pendingIntent ??= _PendingIntent();
    intent.navItems = items;
    intent.selectedItemId = selectedItemId;
    intent.notifyLoaded = notifyLoaded;
    _scheduleIntentPass();
  }

  /// The window pass itself, unchanged from Phase 3 except that it is now
  /// reached from [_runIntentPass] instead of directly from the entrance. It
  /// still contains no await from its first line to its last.
  void _issueNavigationPass({
    required List<PhotoItem> items,
    required String selectedItemId,
    required VoidCallback notifyLoaded,
  }) {
    if (items.isEmpty) return;

    // Snapshot. `items` belongs to the CALLER (AppState hands us its live
    // photo list), and a folder reload clears that list -- after which
    // `items.length - 1` is -1 and the window clamp below throws
    // ArgumentError.
    //
    // Since Phase 3 this method itself no longer awaits, so the clamp cannot
    // be reached across an async gap in THIS frame; the snapshot still stands
    // because the per-slot chains it launches ([_issueWindowItem]) hold this
    // list across their own awaits. The aliasing was always the bug: indices
    // computed from a list that another object may mutate are only ever
    // accidentally correct.
    items = List<PhotoItem>.of(items);

    // This call's generation. Every later navigation event -- and every folder
    // reload, via [reset] -- supersedes it, so the per-slot chain launched
    // below re-checks it after its probe, before acting on a window that may
    // already be history.
    final generation = ++_previewGeneration;

    final currentIndex = items.indexWhere((item) => item.id == selectedItemId);
    if (currentIndex == -1) return;

    // ONE window, ONE eviction rule, identical for every payload kind (user
    // decision D4). Anything dropped here would get a NEW payload if it is
    // loaded again later, so the tier-2 entry decoded for its OLD payload is
    // orphaned and must be evicted rather than left under a stale id -> key
    // mapping (round-2 review BLOCKER 1).
    final neededIds = retentionWindowIds(
      items,
      currentIndex,
      (item) => item.id,
      before: retention.before,
      after: retention.after,
    );
    _navRetentionIds = neededIds;
    // The UNION, never the navigation window alone: retaining only the nav
    // window here would drop every payload the sidebar just filled (plan R-3).
    for (final id in _cache.retainOnly(_retentionIds)) {
      _tierTwo.evict(id);
    }
    // The tier-2 id set moves NOW, not when the debounce fires: a serial decode
    // can land at any moment and its piggyback publish needs a truthful answer
    // to "is this item in the full-size window" (see
    // [TierTwoScheduler.updateWindow]). Nothing about WHEN tier-2 decodes run
    // changes -- that is still [TierTwoScheduler.schedule]'s debounce.
    _tierTwoScheduler.updateWindow(items, currentIndex);
    _selectedId = selectedItemId;

    // PERF-INSTRUMENTATION
    final wasInFlight = _claims.isHeld(selectedItemId);
    final wasCached = _cache.contains(selectedItemId);
    PerfLog.log(
      'preload.priority.begin|$selectedItemId'
      '|cached=$wasCached|inFlight=$wasInFlight',
    );
    // PHASE 3: the selected item has NO awaited pass of its own any more. It
    // is issued below at distance 0 -- first in near-to-far order, therefore
    // first onto the lane and at the lowest (best) rank -- through the same
    // probe-then-route path every other slot uses, carrying `notifyLoaded`.
    // The `await _ensurePayload(items[currentIndex], ...)` that used to stand
    // here made the WHOLE pass wait for a cheap selection's decode+encode
    // (plan §8-D1: an expensive one never waited, it enqueues and returns), so
    // tier-1 precache and the tier-2 arming below sat behind it for no reason.
    //
    // The `generation != _previewGeneration` guard that used to follow it went
    // with it -- guards are only removed together with the await they guarded
    // (plan risk R4). Every surviving await keeps its guard: the per-slot one
    // moved into [_issueWindowItem], and `_folderGeneration` is untouched.

    final startIdx = (currentIndex - retention.before).clamp(
      0,
      items.length - 1,
    );
    final endIdx = (currentIndex + retention.after).clamp(0, items.length - 1);
    // NEAR-TO-FAR, not start-to-end: an expensive item does not load here, it
    // is ENQUEUED on the serial lane, and the lane's start order is the order
    // this loop hands it (0, +1, -1, +2, -2, +3, -3, +4, +5 -- user ruling
    // 2026-08-26). Cheap items are order-insensitive because they all start in
    // parallel anyway, so one loop serves both kinds.
    //
    // The awaits below therefore complete as soon as every cheap load has
    // landed and every expensive one has been QUEUED. That is deliberate:
    // tier-2 scheduling must not wait for the lane to drain, or a nine-slot
    // RAW window would push the full-size decode of the item the user is
    // looking at behind eight decodes it does not need yet.
    final nearToFarOrder = _nearToFarIndices(
      currentIndex,
      startIdx,
      endIdx,
    ).toList();
    // Eviction rank is NOT the load order: budget eviction drops the id
    // farthest OUTSIDE the tier-2 full-size band (-kTierTwoBefore..
    // +kTierTwoAfter) first — -3, then +5, then -2, then +4 — and only then
    // walks the band itself far-to-near (user ruling 2026-09-03, replacing
    // the symmetric farthest-from-selection rule of 2026-08-27). Behind-side
    // ids lose ties because navigation is predominantly forward.
    _navPriorityIds = [
      for (final i in _evictionOrderIndices(currentIndex, nearToFarOrder))
        items[i].id,
    ];
    _republishEvictionPriority();
    // Round-1 review blocker 1 (2026-08-30): the classify probe used to be
    // interleaved with the lane enqueue inside a single concurrent
    // `_ensurePayload` call per item, so lane arrival order was whichever
    // probe's `await` happened to land first -- IO-jittered, not the
    // near-to-far order this loop hands out. Fixed by splitting the pass
    // into two phases: probe every item first (all the awaiting happens
    // here, order-independent), then route them -- including every serial
    // lane enqueue -- synchronously in ONE burst in near-to-far order below,
    // so the lane always sees the ruled start order regardless of width.
    // PHASE 3: the two barriers this loop used to raise -- `Future.wait` over
    // every window probe, then `Future.wait` over every routed load -- are
    // gone. Each slot is issued as its own unawaited probe-then-route chain
    // ([_issueWindowItem]); the pass itself contains no await from here to its
    // end, so tier-1 precache and tier-2 arming below happen on THIS turn of
    // the event loop rather than after every window item's file IO.
    //
    // The near-to-far walk survives and still decides the rank each slot is
    // enqueued with (`laneRankFor(distance)` inside `_enqueueSerialLoad`).
    // That rank -- not this loop's completion order -- is what the lane sorts
    // by, which is why removing the barrier does not re-open the round-1
    // IO-jitter defect (plan risk R8).
    for (final i in nearToFarOrder) {
      unawaited(
        _issueWindowItem(
          items[i],
          distance: i - currentIndex,
          // The selected slot carries the caller's repaint callback; every
          // other slot notifies through the payload-landing path.
          notifyLoaded: i == currentIndex ? notifyLoaded : null,
          generation: generation,
        ),
      );
    }
    PerfLog.log('preload.window.end|$selectedItemId'); // PERF-INSTRUMENTATION

    // No generation check here any more, and deliberately so: there is no
    // await between `++_previewGeneration` at the top of this method and this
    // line, so `generation == _previewGeneration` holds unconditionally. A
    // check that cannot fail is worse than no check -- it reads as protection
    // that is not there. TierTwoScheduler.schedule still CANCELS its debounce
    // before re-arming, so a later pass overwrites this arming rather than
    // racing it.
    _precacheTierOneWindow(items, currentIndex);
    // PHASE 5: the scheduler's landing callback also refreshes the per-item
    // notifiers. `notifyLoaded` itself is still called exactly once per
    // landing (pin B3) -- the wrapper adds a read of the tier-2 registry, not
    // a second notification.
    _tierTwoScheduler.schedule(
      items,
      currentIndex,
      _withTierTwoStates(notifyLoaded),
    );
  }

  /// The id the current pass selected. Read by the pacer's exempt-claim
  /// predicate (deliverable 3) as well as by the perf log, which is why it is
  /// no longer tagged PERF-INSTRUMENTATION: it now carries production logic.
  String? _selectedId;

  /// [startIdx]..[endIdx] walked outwards from [currentIndex]: the selected
  /// slot, then +1, -1, +2, -2, ... skipping whatever the clamp cut off.
  ///
  /// This IS the serial lane's start order (contract criterion 4), so it lives
  /// next to the pass that feeds the lane rather than inside it: the lane
  /// orders by the rank it is handed, and the rank comes from the same signed
  /// distance this walk uses ([laneRankFor]).
  static Iterable<int> _nearToFarIndices(
    int currentIndex,
    int startIdx,
    int endIdx,
  ) sync* {
    if (currentIndex >= startIdx && currentIndex <= endIdx) yield currentIndex;
    final maxDistance = math.max(
      currentIndex - startIdx,
      endIdx - currentIndex,
    );
    for (var d = 1; d <= maxDistance; d++) {
      if (currentIndex + d <= endIdx) yield currentIndex + d;
      if (currentIndex - d >= startIdx) yield currentIndex - d;
    }
  }

  /// [nearToFarOrder] re-ranked for EVICTION: ids beyond the tier-2 band
  /// (-[kTierTwoBefore]..+[kTierTwoAfter]) sort last (evicted first), farthest
  /// beyond the band's nearest edge first; in-band ids keep the near-to-far
  /// walk order. At equal beyond-band distance the behind (-) side sorts after
  /// the ahead (+) side, so it is evicted first. Load/lane order is untouched
  /// — this list feeds [PhotoPayloadCache.setEvictionPriority] only.
  static List<int> _evictionOrderIndices(
    int currentIndex,
    List<int> nearToFarOrder,
  ) {
    int outsideBand(int i) {
      final d = i - currentIndex;
      if (d > kTierTwoAfter) return d - kTierTwoAfter;
      if (d < -kTierTwoBefore) return -kTierTwoBefore - d;
      return 0;
    }

    return nearToFarOrder.toList()..sort((a, b) {
      final oa = outsideBand(a);
      final ob = outsideBand(b);
      if (oa != ob) return oa - ob;
      final da = a - currentIndex;
      final db = b - currentIndex;
      if (oa == 0 && da.abs() != db.abs()) return da.abs() - db.abs();
      // Beyond the band, distance-to-selection is irrelevant: at equal
      // beyond-band distance the behind (-) side always loses the tie.
      return (da < 0 ? 1 : 0) - (db < 0 ? 1 : 0);
    });
  }

  /// Flushes the callbacks parked by callers who selected [id] while somebody
  /// else's load for it was already in flight or queued.
  ///
  /// Reached from EVERY resolution path, including the early returns: an item
  /// that was queued on the serial lane and then landed by another route (a
  /// tier-2 catch-up load, say) still has to release its spinner. Before the
  /// lane existed the only producer was the load itself, so the early returns
  /// could not strand anyone; now they can.
  void _flushPendingNotifies(String id) {
    final pending = _pendingPreviewNotifies.remove(id);
    for (final cb in pending ?? const <VoidCallback>[]) {
      cb();
    }
  }

  /// Produces and retains [item]'s payload if it is not retained already.
  ///
  /// [distance] is the SIGNED offset from the selection (negative = before it).
  /// It no longer decides whether the item may be loaded at all -- since the
  /// 2026-08-26 ruling every retained slot is eligible -- only the near-to-far
  /// rank an expensive item gets on the serial lane.
  ///
  /// [onSerialLane] is true only when this call IS the lane's task body. That
  /// is the one context in which a real RAW decode may run; every other caller
  /// that meets an expensive item enqueues it and returns.
  /// The cache-hit / permanent-miss / already-in-flight fast paths shared by
  /// [_ensurePayload] and [_probeWindowItem]. Returns true if [id] is
  /// already resolved (nothing more for the caller to do).
  bool _earlyResolve(String id, VoidCallback? notifyLoaded) {
    if (_cache.contains(id)) {
      // PERF-INSTRUMENTATION
      PerfLog.log(
        'loadPreview.skip|$id|cached=true|inFlight=false'
        '|isSelected=${id == _selectedId}',
      );
      // No notifyLoaded call here: the payload was already there when this
      // caller asked, so there is nothing new to repaint for IT. Parked
      // callbacks are a different matter -- they are waiting for the item to
      // become available at all, and it now is.
      _flushPendingNotifies(id);
      return true;
    }

    // An answer that cannot change: do not re-ask any source for it.
    if (_permanentMisses.contains(id)) {
      notifyLoaded?.call();
      _flushPendingNotifies(id);
      return true;
    }

    if (_claims.isHeld(id)) {
      // Someone else's load for this item is already in flight (queued by a
      // previous pass, or the caller selected an item that is mid-window-load).
      // Register to be notified when it lands instead of dropping the callback,
      // which used to strand the spinner forever.
      if (notifyLoaded != null) {
        _pendingPreviewNotifies.putIfAbsent(id, () => []).add(notifyLoaded);
      }
      // PERF-INSTRUMENTATION
      PerfLog.log(
        'loadPreview.skip|$id|cached=false|inFlight=true'
        '|isSelected=${id == _selectedId}',
      );
      return true;
    }

    return false;
  }

  /// Phase 1 of the window pass (round-1 review blocker 1 fix): runs the
  /// same fast paths and content probe [_ensurePayload] would, but stops
  /// short of routing -- no lane enqueue, no decode -- so every item's probe
  /// can be awaited concurrently WITHOUT any of them racing each other onto
  /// the serial lane. Returns null when [item] was already resolved by a
  /// fast path (nothing left for phase 2).
  Future<
    ({
      PhotoItem item,
      int distance,
      VoidCallback? notifyLoaded,
      ProbeResult probe,
    })?
  >
  _probeWindowItem(
    PhotoItem item, {
    required int distance,
    required VoidCallback? notifyLoaded,
  }) async {
    final id = item.id;
    // [notifyLoaded] is non-null only for the SELECTED slot. Since Phase 3 the
    // selected item has no separate awaited pass of its own -- it is issued
    // through this very path at distance 0 -- so its callback must travel with
    // it from here, including through the fast paths [_earlyResolve] owns
    // (cached / permanent miss / already in flight). Passing `null` here would
    // strand the preview's spinner whenever the selection was already in
    // flight from a previous pass.
    if (_earlyResolve(id, notifyLoaded)) return null;
    final file = item.bestFileToLoad;
    if (file == null) return null;
    debugProbeInvocationCount++;
    final probed = await _scheduler.classify(
      id,
      file.path,
      longEdge: _longEdge,
    );
    return (
      item: item,
      distance: distance,
      notifyLoaded: notifyLoaded,
      probe: probed,
    );
  }

  /// Issue ONE window slot: probe it, then route it. Phase 3 replaced the
  /// two-barrier pass (`await Future.wait(probeFutures)` then
  /// `await Future.wait(pendingLoads)`) with one of these per slot, launched
  /// unawaited in near-to-far order. The pass therefore no longer waits for
  /// the SET of probes before arming tier-1 precache and tier-2 -- each
  /// probe's completion routes its own item and nobody else's.
  ///
  /// Ordering is NOT delegated to arrival order: `_ensurePayload` performs its
  /// serial-lane enqueue synchronously when handed a `precomputedProbe`, and
  /// that enqueue carries `laneRankFor(distance)`. The lane is a min-priority
  /// queue, so IO jitter can change which slot is enqueued first but not which
  /// pending slot runs next (plan risk R8 -- the property is asserted on
  /// `debugLanePendingPriorityFor`, never on enqueue order).
  ///
  /// [generation] is the issuing pass's `_previewGeneration`. It is re-checked
  /// after the probe's await for exactly the reason the removed barrier's
  /// check existed: a newer selection (or a folder reload, via [reset]) owns
  /// the scheduling state by then. `_folderGeneration` is a different counter
  /// with a different job and is checked where it always was, inside
  /// [_completeOutcome].
  Future<void> _issueWindowItem(
    PhotoItem item, {
    required int distance,
    required VoidCallback? notifyLoaded,
    required int generation,
  }) async {
    final probed = await _probeWindowItem(
      item,
      distance: distance,
      notifyLoaded: notifyLoaded,
    );
    if (probed == null) return;
    if (generation != _previewGeneration) return;
    await _ensurePayload(
      probed.item,
      distance: probed.distance,
      notifyLoaded: probed.notifyLoaded,
      precomputedProbe: probed.probe,
    );
  }

  Future<void> _ensurePayload(
    PhotoItem item, {
    required int distance,
    required VoidCallback? notifyLoaded,
    bool onSerialLane = false,
    ProbeResult? precomputedProbe,
  }) async {
    final id = item.id;
    if (_earlyResolve(id, notifyLoaded)) return;

    final file = item.bestFileToLoad;
    if (file == null) return;

    // The FOLDER this load belongs to. Read before any await, checked again in
    // [_completeOutcome] -- see [_folderGeneration] for why this is not
    // `_previewGeneration`.
    final loadGeneration = _folderGeneration;

    // THE CLAIM, taken here and not after the probe (verdict 2026-08-30 fix A).
    // `_earlyResolve` above read `_claims`; taking the claim after the
    // `classify` await below left a suspension point between check and claim,
    // so two entrants for the same id both passed the check and both bought a
    // source load -- and the second `_cache.put` replaced the payload object,
    // orphaning the tier-1 ImageCache key (which is bytes identity). Every
    // exit below removes it again: the expensive-route hand-off, the probe's
    // catch, and the `finally`.
    // The claim OBJECT is kept, not just the id: every release below hands it
    // back, so a release that outlived a `reset()` (or a lane hand-off and
    // re-acquire) is matched by identity and becomes a genuine no-op instead of
    // stealing whoever holds the id now. See [PayloadClaimRegistry.release].
    final claim = _claims.acquire(id);
    // PHASE 5: the claim IS the "decoding" event -- the same instant that
    // makes every other caller park instead of producing.
    _markStage(id, PayloadStage.decoding);

    // CONTENT PROBE FIRST, for every item at every distance (user Amendment 3
    // clause 2). The probe is what decides the LANE, so anything it does not
    // see gets scheduled on the bridge's say-so instead -- and the bridge is
    // reached by making the very call the probe exists to anticipate.
    //
    // An earlier revision skipped the probe for the selected item and its
    // immediate neighbours, on the grounds that they were about to ask the
    // bridge anyway and the JPEG hot path must cost no Dart CPU. That is the
    // location-dependent classification the user rejected verbatim. The price
    // of the correction is one bounded open (2 bytes for a JPEG, design §5's
    // hot path intact).
    final ProbeResult probed;
    try {
      probed =
          precomputedProbe ??
          await _scheduler.classify(id, file.path, longEdge: _longEdge);
    } catch (_) {
      // The claim is now taken BEFORE this await, and this await is outside
      // the `try/finally` below, so a probe that throws would strand the id
      // in `_claims` forever -- every later caller would park on a load
      // that will never land. Error propagation is unchanged.
      _claims.release(id, by: PayloadClaimOwner.producer, claim: claim);
      rethrow;
    }
    final cost = probed.cost;
    // First writer wins, and after the change above the probe is the first
    // writer whenever it was conclusive. The bridge's orientation (below)
    // survives only as the A-§2 rung-2 fallback, for files the probe could not
    // measure at all.
    final probedOrientation = probed.exifOrientation;
    if (probedOrientation != null) {
      _exifOrientations.putIfAbsent(id, () => probedOrientation);
    }
    // LANE ROUTING (user ruling 2026-08-26, replacing the ±1 rung refusal).
    // A measured-expensive item is not refused any more, at any distance: the
    // WHOLE load is handed to the serial lane, which runs it near-to-far with
    // one decode in flight. Everything else about it -- retention, tier-1
    // precache, tier-2 eligibility -- is identical to a cheap item's.
    if (cost == SourceCost.expensive && !onSerialLane) {
      // Released BEFORE the hand-off: the lane body re-enters `_ensurePayload`
      // for this same id, and a stale claim would send it down the
      // `_earlyResolve` in-flight branch -- it would park its callback and
      // produce nothing, i.e. a permanent spinner. Production of this payload
      // now belongs to the lane task, which takes its own claim.
      _claims.handOffToLane(
        id,
        from: PayloadClaimOwner.producer,
        claim: claim,
      );
      _enqueueSerialLoad(item, distance: distance, notifyLoaded: notifyLoaded);
      return;
    }

    final tCh = PerfLog.us; // PERF-INSTRUMENTATION
    // Set when the encode is handed to [_finishOffLane]: the production claim
    // then belongs to that continuation, not to this `finally`.
    var handedOff = false;
    try {
      // Only the lane's own task body may run a real RAW decode. Everywhere
      // else `allowExpensive: false` is what makes the bridge answer
      // NeedsRawDecode instead of decoding inline -- which is how an item the
      // probe could not measure gets discovered and handed to the lane below.
      final canDoExpensive = onSerialLane;
      final knownOrientation = _exifOrientations[id];
      // FIX 2026-09-02 (field defect, docs/logs/2026-09-02/h3-routing-findings.md
      // §0-Z): the COST test below is load-bearing and used to be absent.
      //
      // `loadExpensive` calls the decoder DIRECTLY and never asks the loader,
      // so taking it for a cheap item throws away a perfectly usable embedded
      // preview and renders the photo from sensor data instead -- visibly
      // different colours. `knownOrientation != null` was written as a proxy
      // for "an earlier pass already got NeedsRawDecode from the bridge and
      // carried the orientation forward" (invariant I6), but the CONTENT PROBE
      // is a second writer of that memo and fills it for every measured
      // TIFF/RAW, cheap ones included -- so the proxy became true for every RAW
      // file and this branch degenerated into "RAW-decode anything that reaches
      // the serial lane". Cheap items reach it routinely through two cost-blind
      // callers (the sidebar payload lane and the tier-2 catch-up load), which
      // is why the affected set looked random and re-rolled every launch.
      //
      // I6 is preserved: a genuinely expensive item's rung is memoised before
      // the lane hand-off (by the probe, or by `observe(..., by: 'bridge')`
      // below for the deferred route), so `classify` returns `expensive` on
      // lane re-entry and `loadExpensive` still resumes without a second round
      // trip. A cheap item now takes `load(allowExpensive: true)`: the loader
      // is asked, and a genuine extraction failure still decodes inline on the
      // lane exactly as before. `cost == null` (unmeasurable) also routes to
      // `load`, which is what the frozen A-§2 rung-2 contract requires -- the
      // bridge decides, so the bridge must be asked.
      // F5/AC7: read ONCE, before the await, and reuse for the memo below. The
      // memo now records WHICH long edge a verdict was measured at, so the
      // value stored must be the one this load actually used -- a resize
      // landing inside the await would otherwise file this answer under a
      // viewport that never asked the question.
      final loadLongEdge = _longEdge;
      // PERF-INSTRUMENTATION (D1 AC3 marker): tier-1/tier-2 request start.
      PerfLog.log(
        'req_start|id=$id|tier=${onSerialLane ? "lane" : "parallel"}'
        '|expensive=$canDoExpensive|longEdge=$loadLongEdge',
      );
      final decode =
          canDoExpensive &&
              cost == SourceCost.expensive &&
              knownOrientation != null
          ? await _source.decodePhaseExpensive(
              file.path,
              longEdge: loadLongEdge,
              exifOrientation: knownOrientation,
            )
          : await _source.decodePhase(
              file.path,
              longEdge: loadLongEdge,
              allowExpensive: canDoExpensive,
            );
      // PERF-INSTRUMENTATION (D1 AC3 markers + gap #5): request end + decode
      // phase result, now carrying the payload classification round-2
      // needs to pick between H1/H2 (EncodedPayload path) vs H4
      // (PixelPayload/RAW path). `pixels != null` marks a real RAW/full
      // decode ran; otherwise this was an embedded-preview/bitmap byte
      // handoff (dart_image_loader).
      final payloadKind = decode.pixels != null
          ? 'Pixel'
          : (decode.encodedPayload != null ? 'Encoded' : 'none');
      PerfLog.log(
        'req_end|id=$id|dur=${PerfLog.us - tCh}'
        '|rawDecode=${decode.pixels != null}'
        '|payloadKind=$payloadKind'
        '|bytes=${decode.encodedPayload?.byteCost ?? decode.pixels?.byteCost ?? -1}'
        '|cost=${decode.observedCost}'
        '|exifOrientation=${decode.exifOrientation}',
      );
      PerfLog.log(
        'decode|id=$id|rawDecode=${decode.pixels != null}'
        '|dur=${PerfLog.us - tCh}',
      );

      // THE STAGE BOUNDARY. A real decode ran and an encode is owed, and this
      // call IS the lane's task body -- so return now and let the encode run
      // on its own stage. The lane slot is freed here; the production
      // claim is NOT (see [_finishOffLane]).
      if (onSerialLane && decode.pixels != null) {
        // The claim moves with the work: `_finishOffLane`'s `finally` is the
        // only thing that releases it from here. Transferred BEFORE the
        // `unawaited` below, because that continuation can begin before this
        // method returns -- and `handedOff` is set only AFTER the transfer, so
        // that a throw from `transfer` cannot leave the flag true with the
        // claim still owned by the producer (nobody would then release it).
        _claims.transfer(
          id,
          from: PayloadClaimOwner.producer,
          to: PayloadClaimOwner.offLaneEncode,
          claim: claim,
        );
        handedOff = true;
        unawaited(
          _finishOffLane(
            item,
            decode: decode,
            distance: distance,
            notifyLoaded: notifyLoaded,
            loadLongEdge: loadLongEdge,
            loadGeneration: loadGeneration,
            claim: claim,
          ),
        );
        return;
      }

      final outcome = await _source.encodePhase(decode);
      // PERF-INSTRUMENTATION. Emitted by the CALLER rather than from inside
      // [_completeOutcome], because the round trip it reports is measured from
      // this method's entry -- the off-lane continuation has its own start
      // instant and reports its own interval.
      PerfLog.log(
        'channel.preview|$id|bytes=${outcome.payload?.byteCost ?? -1}'
        '|roundtrip=${PerfLog.us - tCh}|notify=${notifyLoaded != null}'
        '|isSelected=${id == _selectedId}',
      );
      // A deferred outcome hands both the work and the production claim to
      // the lane; the `finally` below must not take the claim back off it.
      if (await _completeOutcome(
        item,
        outcome: outcome,
        distance: distance,
        notifyLoaded: notifyLoaded,
        onSerialLane: onSerialLane,
        claim: claim,
        loadLongEdge: loadLongEdge,
        loadGeneration: loadGeneration,
      )) {
        handedOff = true;
      }
    } catch (_) {
      // A source threw (e.g. a PlatformException the native side did not
      // convert to null, or a MissingPluginException on an unimplemented
      // platform handler). Flush anyone who selected this item while the load
      // was in flight so they do not strand on a permanent spinner and the
      // pending-notify map does not grow unbounded -- same rationale as the
      // success path, reached via the exception path (round-2 review S1).
      // Preserve existing error propagation.
      final pending = _pendingPreviewNotifies.remove(id);
      if (pending != null) {
        for (final cb in pending) {
          cb();
        }
      }
      rethrow;
    } finally {
      // NOT released on the hand-off path: production of this payload now
      // belongs to [_finishOffLane], and a released claim would let a second
      // producer decode the same file while the first is still encoding.
      if (!handedOff) {
        _claims.release(id, by: PayloadClaimOwner.producer, claim: claim);
      }
    }
  }

  /// The encode half of an expensive load, run OFF the [DecodeLane].
  ///
  /// The lane slot was released when `_ensurePayload` returned, so the ~89ms
  /// encode no longer blocks the next decode. Two things must therefore be
  /// true here and are:
  ///
  ///   * the production claim still holds [item]'s id -- released only in this
  ///     method's `finally`. Releasing it at lane-body return would let a
  ///     second producer start a duplicate decode while this encode runs.
  ///   * nothing is unawaited-and-unguarded: this future has no caller, so a
  ///     throw here would be an unhandled async error AND a stranded spinner.
  ///     Both are handled below, mirroring `DecodeLane._runOne`'s "one item's
  ///     failure must not wedge the pipeline" rule.
  Future<void> _finishOffLane(
    PhotoItem item, {
    required SourceDecode decode,
    required int distance,
    required VoidCallback? notifyLoaded,
    required int loadLongEdge,
    required int loadGeneration,
    required PayloadClaim claim,
  }) async {
    final id = item.id;
    final tCh = PerfLog.us; // PERF-INSTRUMENTATION
    // Sized from what this decode is actually holding. Acquired AFTER the
    // decode, never before: a pre-decode acquire would put a second admission
    // gate in front of [DecodeLane] and the two could deadlock against each
    // other's width.
    final bytes =
        decode.fullRes?.rgba.lengthInBytes ?? decode.pixels?.byteCost ?? 0;
    // The epoch this admission belongs to. This continuation is unawaited by
    // design, so `dispose()`/`reset()` -> `InflightBytesBudget.clear()` can run
    // between the acquire and the release below; releasing against a stale
    // epoch is then a no-op instead of an over-release (BUG 2026-09-03,
    // TC-886).
    final budgetEpoch = await _inflight.acquire(bytes);
    try {
      final outcome = await _encodeStage.run(() => _source.encodePhase(decode));
      PerfLog.log(
        'channel.preview|$id|bytes=${outcome.payload?.byteCost ?? -1}'
        '|roundtrip=${PerfLog.us - tCh}|notify=${notifyLoaded != null}'
        '|isSelected=${id == _selectedId}',
      );
      // `onSerialLane: true` makes the deferred hand-off unreachable, so the
      // claim is always still this method's to release below.
      await _completeOutcome(
        item,
        outcome: outcome,
        distance: distance,
        notifyLoaded: notifyLoaded,
        onSerialLane: true,
        loadLongEdge: loadLongEdge,
        loadGeneration: loadGeneration,
        claim: claim,
      );
    } catch (_) {
      // Same rationale as `_ensurePayload`'s catch: flush anyone parked on
      // this item so they do not strand on a permanent spinner, and release
      // the handle nobody will publish. No rethrow -- there is no caller.
      decode.fullRes?.image?.dispose();
      final pending = _pendingPreviewNotifies.remove(id);
      for (final cb in pending ?? const <VoidCallback>[]) {
        cb();
      }
    } finally {
      // Released exactly once, after [_completeOutcome] has either retained or
      // dropped the payload -- the buffers are only out of flight then.
      _inflight.release(bytes, epoch: budgetEpoch);
      // [claim] plays the role `budgetEpoch` plays for the byte budget on the
      // line above, though it matches by object identity rather than by
      // counter. This future is unawaited and can outlive the `reset()` that
      // cleared the registry; passing the claim back makes that late release a
      // no-op instead of an assertion failure against -- and a theft of -- a
      // fresh producer's claim on the same id.
      _claims.release(id, by: PayloadClaimOwner.offLaneEncode, claim: claim);
    }
  }

  /// Everything that happens once an outcome exists: cost memo, orientation
  /// memo, cache write, sidebar hand-off, tier-1 precache, permanent-miss
  /// bookkeeping, lane hand-off for a deferred item, notify, piggyback.
  ///
  /// Extracted so BOTH the inline path and the off-lane encode continuation
  /// run identical code. It is a MOVE, not a rewrite.
  ///
  /// Every staleness re-check inside it is now behind one MORE await than it
  /// used to be (the encode), which is exactly why none of them may be
  /// weakened or hoisted (G-023).
  /// Returns true when this call handed [item] to the [DecodeLane] AND handed
  /// the production claim over with it (the deferred route below). The
  /// caller must then NOT release that claim in its own `finally`.
  Future<bool> _completeOutcome(
    PhotoItem item, {
    required SourceOutcome outcome,
    required int distance,
    required VoidCallback? notifyLoaded,
    required bool onSerialLane,
    required int loadLongEdge,
    required int loadGeneration,
    required PayloadClaim claim,
  }) async {
    final id = item.id;

    // FOLDER GATE. Everything below this point writes into state that
    // [reset] has just cleared for a DIFFERENT folder: the cost memo, the
    // payload cache, the sidebar, and -- the damaging one -- the
    // `_permanentMisses` latch. An in-flight expensive load cannot be
    // cancelled (no FFI decode is), so this is the only place the result of
    // one can be refused.
    //
    // Same shape as the "left the window while the load was in flight"
    // early-out below, for the same reason: release the parked callbacks so
    // nobody strands on a spinner, hand the piggyback handle no new owner, and
    // record NOTHING. Deliberately not special-cased to the pool's discard
    // exception -- a stale SUCCESS is just as wrong to land as a stale
    // failure, and both arrive here.
    if (loadGeneration != _folderGeneration) {
      outcome.fullRes?.image?.dispose();
      _flushPendingNotifies(id);
      return false;
    }

    _scheduler.observe(id, outcome.observedCost, longEdge: loadLongEdge);
    // Rung-2 only: reached when the probe could not measure the file, so the
    // bridge answer is the sole orientation available (frozen contract A-§2).
    if (outcome.exifOrientation != null) {
      _exifOrientations.putIfAbsent(id, () => outcome.exifOrientation!);
    }
    final payload = outcome.payload;

    if (payload != null) {
      // The orientation memo deliberately SURVIVES a successful load. It is
      // a property of the file, not of this attempt; dropping it here would
      // make an item that leaves the retention window and comes back buy it
      // again from the bridge, which is the round trip I6 forbids.
      if (!_retentionIds.contains(id)) {
        // Left the window while the load was in flight. Release parked
        // callbacks (review F-3 fix, 2026-08-27) -- same pattern as the
        // lane body's window refusal. The piggyback handle has no other
        // owner from here, so it is released too (I-DISPOSE).
        outcome.fullRes?.image?.dispose();
        _flushPendingNotifies(id);
        return false;
      }
      _cache.put(id, payload);
      // PHASE 5: the per-item twin of the `notifyLoaded?.call()` below. It
      // sits at the cache write, not next to the callback, because EVERY
      // landing writes here while only the selected slot carries a callback.
      _markStage(id, PayloadStage.tierOneReady);
      // PERF-INSTRUMENTATION (D1 AC3 marker): payload publish.
      PerfLog.log(
        'publish|id=$id|bytes=${payload.byteCost}'
        '|onSerialLane=$onSerialLane|isSelected=${id == _selectedId}',
      );
      // Whoever produced it, the sidebar's waiters get their tile from THIS
      // payload -- never from a second decode of their own (D5 decision 2).
      _sidebar.onPayloadLanded(id, payload);
      // A landed payload gets its tier-1 ImageCache entry HERE, not on "the
      // next navigation pass": when the user has stopped navigating there is
      // no next pass, and the item would sit retained with nothing decoded
      // for it -- the very stall the 2026-08-26 ruling exists to remove.
      //
      // PHASE 3 made this unconditional. It used to be `if (onSerialLane)`,
      // on the grounds that a CHEAP item's parallel load landed before
      // [_precacheTierOneWindow] ran "microseconds later" at the tail of the
      // window pass's awaits. Those awaits are gone: the batched sweep now
      // runs synchronously, i.e. BEFORE any cheap load of this pass has
      // landed, so the batched route no longer covers cheap items on the pass
      // that produced them. This call is the landing-driven replacement.
      // [_precacheTierOneWindow] is kept for what only it does -- decoding
      // slots that were already retained when the pass started, and evicting
      // tier-1 keys that left the window.
      //
      // Idempotent by construction: [_decodeIntoImageCache] is keyed on the
      // payload's bytes identity, so the batched sweep meeting the same
      // payload again is an ImageCache hit, not a second decode (pin B1).
      _precacheTierOneFor(id, payload, distance: distance);
    } else if (!outcome.deferred) {
      // Every source failed, including the legacy fallback. Mark it so the
      // view can say "unreadable" instead of spinning forever, and so no
      // later pass asks again. This is the load-bearing edge of design §3.4:
      // the ONLY new stranding risk in M3 is a failure that nobody records.
      _permanentMisses.add(id);
      // PHASE 5: terminal for this folder, exactly like the latch it mirrors.
      _markStage(id, PayloadStage.failed);
      _sidebar.onPayloadMiss(id);
      // DIAGNOSTIC (2026-09-02). THE latch: from here nothing re-asks about
      // this item until the folder reloads (`_earlyResolve`'s permanent-miss
      // branch), so whatever caused this one failure is frozen for the whole
      // session. One line per id per folder load, bounded by the set that was
      // just written -- the same volume budget
      // `SidebarThumbnailController.logFailure` has.
      debugPrint(
        'halcyon.preview.latch|id=$id|code=${outcome.failureCode ?? 'none'}'
        '|cost=${outcome.observedCost}|-> unreadable for this session',
      );
      // D3 (docs/logs/2026-08-26/raw-support-contract.md): PhotoSource
      // decides "no native RAW decoder on this platform" BEFORE invoking
      // anything (a static platform property, not a caught decode
      // failure) and carries it as `outcome.failureCode`, so the
      // disambiguation from every other permanent-miss cause (a genuine
      // decode/read failure, or a D2 browse-only RAW) is just reading the
      // code back, not re-deriving it here.
      if (outcome.failureCode == kNoNativeDecoderCode) {
        _noNativeDecoderMisses.add(id);
      }
    }
    // LANE HANDOFF. A deferred outcome means the probe could not measure the
    // file and the BRIDGE was the one to answer "this needs a real RAW
    // decode" (photo_source.dart's `allowExpensive: false` arm). Such an item
    // must be re-enqueued on the serial lane, never left for a debounced pass
    // to pick up: since the 2026-08-26 ruling the lane is the only producer
    // of expensive payloads, so "wait for the next sweep" would be a spinner
    // with no owner. The bridge's orientation was memoised a few lines above,
    // so the lane's retry uses `loadExpensive` and buys no second round trip
    // (invariant I6).
    var handedToLane = false;
    if (outcome.deferred && !onSerialLane) {
      // THE CLAIM GOES FIRST, exactly as the measured-expensive route in
      // [_ensurePayload] does it (BUG 2026-09-03, TC-357). The lane body
      // re-enters `_ensurePayload` for this same id, and `enqueue` schedules
      // its pump on a MICROTASK -- so the body can, and under width > 1
      // routinely does, run before this call's caller reaches its `finally`.
      // A claim still held at that moment sends the body down
      // `_earlyResolve`'s in-flight branch: it parks nothing, decodes nothing
      // and returns, so the item silently forfeits its ranked turn while a
      // farther one takes the freed slot -- the observed [0, +2, -2] start
      // order. Ownership of the claim moves to the lane task with the work;
      // the caller learns that from this method's return value and leaves it
      // alone.
      _claims.handOffToLane(
        id,
        from: PayloadClaimOwner.producer,
        claim: claim,
      );
      handedToLane = true;
      _enqueueSerialLoad(item, distance: distance, notifyLoaded: notifyLoaded);
    }
    // A deferred item is the one case with nothing to report yet, and its
    // parked callbacks must SURVIVE this call -- they belong to the lane task
    // that will actually produce the payload.
    final resolved = payload != null || _permanentMisses.contains(id);
    if (resolved) {
      notifyLoaded?.call();
      _flushPendingNotifies(id);
    }

    // PIGGYBACK (design §2.2). The source hands back full-resolution oriented
    // pixels ONLY when a real FFI decode ran in this very call, so the
    // full-resolution tier-2 entry costs no extra decoder call -- which is
    // what keeps the hash-frozen navigation probes' "decoder called exactly
    // once" assertions green. Done AFTER the notify above so the window
    // -resolution frame reaches the screen first.
    //
    // The PixelPayload type test is gone because a re-encoded RAW retains an
    // EncodedPayload -- the registry anchors on payload object IDENTITY, not
    // on the payload's kind (raw_full_res_image.dart:45), so this works for
    // both kinds without touching TierTwoRegistry's containers (AD-027
    // intact).
    //
    // The window / payload-identity / already-published checks that used to
    // live here now live inside publishPiggybackFullRes, together with the
    // matching `ui.Image` dispose. Duplicating them here would be a second
    // place that must remember to release a ~50MB handle.
    final fullRes = outcome.fullRes;
    if (fullRes != null) {
      if (payload != null) {
        await _tierTwoScheduler.publishPiggybackFullRes(
          id,
          payload,
          fullRes,
          notifyLoaded,
          distance: distance,
        );
        // PHASE 5: the one tier-2 landing whose id is known at the call site.
        // The registry -- not this line -- decides readiness; publishing can
        // be refused (window, payload identity, already published), so the
        // answer is READ BACK rather than assumed.
        if (_tierTwo.isReady(id)) _markStage(id, PayloadStage.tierTwoReady);
      } else {
        // No payload survived, so no publisher will ever take ownership.
        // This is the one dispose the controller owns.
        fullRes.image?.dispose();
      }
    }
    return handedToLane;
  }

  /// Hands [item]'s whole load to the serial lane at its near-to-far rank.
  ///
  /// The lane body -- not this method -- re-checks the retention window, so a
  /// queued item the user has navigated past starts no decode at all: the check
  /// has to happen when the item's TURN comes, not when it is queued (invariant
  /// I4). A later pass that re-enqueues the same id simply re-ranks the pending
  /// entry, which is how "navigate mid-queue and the next decode is the new
  /// position's nearest missing item" holds without cancelling anything.
  void _enqueueSerialLoad(
    PhotoItem item, {
    required int distance,
    required VoidCallback? notifyLoaded,
  }) {
    final id = item.id;
    // Parked rather than carried on the closure: a re-enqueue REPLACES the
    // pending body, so a callback living only inside the old body would be
    // silently dropped and its spinner would never resolve.
    if (notifyLoaded != null) {
      _pendingPreviewNotifies.putIfAbsent(id, () => []).add(notifyLoaded);
    }
    _decodeLane.enqueue(
      (LaneTaskKind.payload, id),
      // PHASE 4: P1 for the selected slot, P2 for the rest of the window --
      // one classifier call instead of this file's own arithmetic. The rank
      // WITHIN P2 is still the user-ruled near-to-far walk.
      priority: navigationPriorityFor(distance),
      // `distance` is captured at enqueue time and becomes stale after
      // navigation. This is harmless: a navigation re-enqueue REPLACES this
      // body with a fresh distance, so stale distance only survives when the
      // item stays queued from its original enqueue — and the only consumer
      // of `distance` inside the body is _ensurePayload's deferred
      // re-enqueue rank, which the next navigation pass overwrites anyway.
      body: () async {
        // FIRST, ahead of every exit path. The claim was dropped at the
        // hand-off (see [PayloadClaimRegistry.handOffToLane]); this call closes
        // the awaiting-lane record. It must not sit behind the retention
        // early-return below: an item that fell out of the window between
        // enqueue and its turn would leave its id armed in the awaiting-lane
        // set forever, and the NEXT legitimate producer for that id would then
        // be miscounted as a duplicate -- silently corrupting
        // [debugDuplicateProducerCount], which is the only signal the probe
        // verdict and TC-1035 rest on. It gates nothing.
        _claims.assumeFromLane(id);
        if (!_retentionIds.contains(id)) {
          // Out of the window by the time its turn came: no decode, no bridge
          // call. Release any parked callbacks so they do not accumulate
          // unboundedly (review F-3 fix, 2026-08-27). A navigation back to
          // the item re-enqueues and re-parks if needed.
          _flushPendingNotifies(id);
          return;
        }
        await _ensurePayload(
          item,
          distance: distance,
          notifyLoaded: null,
          onSerialLane: true,
        );
      },
    );
  }

  /// Decodes ONE item's tier-1 entry, for a payload that has just landed off
  /// the serial lane. The batched sibling is [_precacheTierOneWindow].
  void _precacheTierOneFor(
    String id,
    SourcePayload payload, {
    required int distance,
  }) {
    final width = _tierOneWidth;
    final height = _tierOneHeight;
    if (width == null || height == null) return;
    // The NAVIGATION window, deliberately NOT the retention union. Since
    // sidebar scrolling produces payloads too (D5 decision 4), a lane body
    // landing a payload for a sidebar-only row reaches here -- and the tier-1
    // ImageCache budget is sized for a handful of window-resolution entries,
    // not for a whole folder. TC-429 is the regression guard.
    if (!_navRetentionIds.contains(id)) return;
    if (!identical(_cache.peek(id), payload)) return;
    _decodeIntoImageCache(
      id,
      _tierOneProviderForPayload(payload, width: width, height: height),
      payload: payload,
      rank: laneRankFor(distance),
      exempt: isSelectedExempt(distance),
    );
  }

  // resolve -> one-shot listener -> removeListener, the dance written three
  // times in this file. The CALLER keeps all bookkeeping: the three sites
  // differ in when they register tier-2 keys and what they do on error, and
  // folding that in here would need a parameter per difference.
  void _registerDecode(
    ImageProvider provider, {
    required void Function() onReady,
    required void Function() onError,
  }) {
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) {
        stream.removeListener(listener);
        onReady();
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        onError();
      },
    );
    stream.addListener(listener);
  }

  // Tier-1 precache: decode the WHOLE -3..+5 retention window at window
  // resolution ahead of display, using the SAME provider factory the view uses.
  // Requires [updateTargetSize] to have been called at least once (from a
  // previous layout pass); no-ops otherwise, degrading to on-demand full decode
  // at display time (functionally correct, just slower for that frame).
  //
  // The span is DERIVED from the retention constants rather than written out
  // again, so a retained slot and a screen-resolution entry cannot drift apart:
  // before round 2 this was a hardcoded +/-2 while retention was -3..+5, which
  // left the four outer slots holding a payload and no ImageCache entry at all,
  // so stepping onto one re-decoded despite the payload being right there.
  //
  // This is a CONSUMER of payloads, never a producer -- it skips a slot with no
  // payload instead of fetching one. That separation is why widening this span
  // can never add a decode: production is the window pass's and the serial
  // lane's business, and this loop only ever decodes what is already retained.
  void _precacheTierOneWindow(List<PhotoItem> items, int currentIndex) {
    final width = _tierOneWidth;
    final height = _tierOneHeight;
    if (width == null || height == null) return;

    final tierStart = (currentIndex - retention.before).clamp(
      0,
      items.length - 1,
    );
    final tierEnd = (currentIndex + retention.after).clamp(0, items.length - 1);
    // Same window the retention-cache sweep in preloadImages used, recomputed
    // from the same constants via the shared helper (C6) so this method's idea
    // of the window and the cache's cannot drift apart. The decode loop below
    // still walks tierStart..tierEnd, not neededIds, because it also decides
    // WHICH slots to decode (skipping ones with no payload yet) -- that is a
    // second job the id set alone does not do.
    final neededIds = retentionWindowIds<PhotoItem>(
      items,
      currentIndex,
      (item) => item.id,
      before: retention.before,
      after: retention.after,
    );

    for (var i = tierStart; i <= tierEnd; i++) {
      final item = items[i];
      final payload = _cache.peek(item.id);
      if (payload == null) continue; // not loaded yet; retried on next pass
      _decodeIntoImageCache(
        item.id,
        _tierOneProviderForPayload(payload, width: width, height: height),
        payload: payload,
        rank: laneRankFor(i - currentIndex),
        exempt: isSelectedExempt(i - currentIndex),
      );
    }

    final staleIds = _tierOneKeys.keys
        .where((id) => !neededIds.contains(id))
        .toList();
    for (final id in staleIds) {
      final key = _tierOneKeys.remove(id);
      if (key != null) {
        PaintingBinding.instance.imageCache.evict(key);
      }
    }
  }

  // The two places a payload becomes a provider. Pixels are ALREADY at window
  // resolution and orientation-corrected -- resizing them again would be a
  // second resample of an image that is already the right size -- so both
  // tiers use the same provider for that kind, which also means they share one
  // ImageCache entry instead of decoding the same pixels twice.
  ImageProvider _tierOneProviderForPayload(
    SourcePayload payload, {
    required int width,
    required int height,
  }) {
    return switch (payload) {
      EncodedPayload(:final bytes) => tierOneProviderFor(
        bytes,
        width: width,
        height: height,
      ),
      PixelPayload() => RawPixelsImage(payload),
    };
  }

  ImageProvider _fullSizeProviderForPayload(SourcePayload payload) {
    return switch (payload) {
      EncodedPayload(:final bytes) => fullSizeProviderFor(bytes),
      PixelPayload() => RawPixelsImage(payload),
    };
  }

  /// Submits ONE tier-1 registration to the pacer.
  ///
  /// Invariant I1: [provider] is built by the CALLER, at submit time, from the
  /// RETAINED payload object, and captured in the closure below. Rebuilding it
  /// at drain time from re-read bytes would produce a different provider key
  /// and silently double-decode.
  ///
  /// [stillValid] re-checks at DRAIN time the same two conditions
  /// [_precacheTierOneFor] checks inline at submit time (G-023): between submit
  /// and drain the id may have left the navigation window or the payload object
  /// may have been replaced.
  void _decodeIntoImageCache(
    String id,
    ImageProvider provider, {
    required SourcePayload payload,
    required int rank,
    required bool exempt,
  }) {
    // PERF-INSTRUMENTATION (D1 gap #3): submit timestamp for the tier-1
    // (window-resolution) registration path, so submit->publish latency is
    // derivable the same way it is for tier-2 (H3's safeguard tax).
    PerfLog.log(
      'submit|id=$id|path=tier1|exempt=$exempt|paced=${!exempt}|rank=$rank',
    );
    _pacer.submit(
      id: id,
      rank: rank,
      exempt: exempt,
      stillValid: () =>
          _navRetentionIds.contains(id) && identical(_cache.peek(id), payload),
      publish: () => _publishTierOneRegistration(id, provider),
      // Nothing is held: a skipped registration degrades to an on-demand decode
      // at display time, which is already this path's documented fallback when
      // [updateTargetSize] has not been called.
      discard: null,
    );
  }

  void _publishTierOneRegistration(String id, ImageProvider provider) {
    // PERF-INSTRUMENTATION (D1 AC3 marker): tier-1 registration lands.
    PerfLog.log('publish|id=$id|path=tier1');
    _registerDecode(provider, onReady: () {}, onError: () {});
    provider
        .obtainKey(const ImageConfiguration())
        .then((key) => _tierOneKeys[id] = key);
  }

  /// Loads sidebar thumbnails for the VISIBLE range [startIdx]..[endIdx],
  /// plus [thumbnailPrefetchMargin] rows of prefetch on each side.
  ///
  /// Forwards to [SidebarThumbnailController.preloadThumbnails], which owns
  /// the whole sweep -- see there for the ordering rationale and for what the
  /// returned Future does and does not promise.
  /// [notifyLoaded] is OPTIONAL since Phase 5 commit B: production passes
  /// nothing, because a landed tile wakes its own row through [stateFor]. It
  /// survives for the sidebar's own unit tests, which use it to observe a
  /// sweep without building a controller-level listener.
  Future<void> preloadThumbnails({
    required List<PhotoItem> items,
    required int startIdx,
    required int endIdx,
    VoidCallback? notifyLoaded,
  }) async {
    // PHASE 6: the viewport half of the same intent record the navigation
    // entrance writes, so a frame that reports a new visible range AND a new
    // selection produces one pass, in a defined order (window, then sweep).
    //
    // [notifyLoaded] bypasses the record deliberately: it is only ever
    // non-null in the sidebar's own unit tests, which call this to observe a
    // single sweep and would learn nothing from a coalesced one.
    if (notifyLoaded != null) {
      return _sidebar.preloadThumbnails(
        items: items,
        startIdx: startIdx,
        endIdx: endIdx,
        notifyLoaded: notifyLoaded,
      );
    }
    final intent = _pendingIntent ??= _PendingIntent();
    intent.thumbItems = items;
    intent.thumbStartIdx = startIdx;
    intent.thumbEndIdx = endIdx;
    _scheduleIntentPass();
  }
}

/// PHASE 6: the ONE mutable intent (plan §3 Phase 6). Deliberately a mutable
/// holder rather than an immutable record: the two entrances write different
/// halves of it at different moments, and the point is that the LAST writer of
/// each half wins before the pass reads them.
class _PendingIntent {
  List<PhotoItem>? navItems;
  String? selectedItemId;
  VoidCallback? notifyLoaded;

  List<PhotoItem>? thumbItems;
  int? thumbStartIdx;
  int? thumbEndIdx;
}
