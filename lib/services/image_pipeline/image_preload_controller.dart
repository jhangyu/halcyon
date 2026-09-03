import 'dart:async';
import 'dart:math' as math;

import 'package:ceyx/ceyx.dart' show CeyxEncodeService;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../models/photo_item.dart';
import '../../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import 'dng_decode_contract.dart';
import 'idle_publish_scheduler.dart';
import 'image_source_types.dart';
import 'payload_reencoder.dart';
import 'photo_payload.dart';
import 'photo_payload_cache.dart';
import 'photo_source.dart';
import 'prefetch_scheduler.dart';
import 'raw_full_res_image.dart';
import 'raw_pixels_image.dart';
import 'retention_policy.dart';
import 'sidebar_thumbnail_controller.dart';
import 'decode_lane.dart';
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
    int encodeStageWidth = 2,
    FrameHook? scheduleFrameCallback,
    int publicationsPerFrame = 1,
    int? inflightByteBudget,
    CompositeGate compositeGate = immediateCompositeGate,
  }) : _retention = retention,
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
       _decodeLane = DecodeLane(width: decodeLaneWidth),
       _encodeStage = EncodeStage(width: encodeStageWidth),
       _cache = PhotoPayloadCache(byteBudget: retention.payloadByteBudget);

  /// How far retention reaches and how many bytes it may hold. Sized from
  /// total physical memory at startup (see retention_policy.dart); the
  /// default is the shipped floor, so every test and every platform without
  /// a memory reading behaves exactly as before. Mutable through
  /// [setRetention] (the user's memory-tier setting), publicly read-only.
  RetentionPolicy _retention;
  RetentionPolicy get retention => _retention;

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
  final PhotoPayloadCache _cache;
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

  /// Live setting change from the settings page. Values below 1 clamp to 1.
  void setDecodeLaneWidth(int width) => _decodeLane.width = width;

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
  );

  /// The JPEG re-encode's own bounded stage. Deliberately NOT the [DecodeLane]:
  /// the encode measured 89ms median and used to hold a decode slot for all of
  /// it, so lane throughput was decode + encode rather than decode alone. The
  /// lane's key-dedup, priority replacement and near-to-far ordering exist to
  /// schedule DECODES; an encode has neither a key space nor a distance.
  final EncodeStage _encodeStage;

  @visibleForTesting
  int get debugEncodeStageRunningCount => _encodeStage.runningCount;

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

  /// Detail-path (tier-1/tier-2) loads in flight, keyed by BARE photo id.
  final Set<String> _loadingKeys = {};

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
    navigationDebounce: tierTwoNavigationDebounce,
    compositeGate: _compositeGate,
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
  bool isLoadingForTest(String id) => _loadingKeys.contains(id);

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
    _cache.clear();
    _sidebar.reset();
    _loadingKeys.clear();
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
    _permanentMisses.clear();
    _noNativeDecoderMisses.clear();
    _exifOrientations.clear();
    _previewGeneration++;
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

  Future<void> preloadImages({
    required List<PhotoItem> items,
    required String selectedItemId,
    required VoidCallback notifyLoaded,
  }) async {
    if (items.isEmpty) return;

    // Snapshot. `items` belongs to the CALLER (AppState hands us its live
    // photo list), this method awaits several times, and a folder reload
    // clears that list in between -- after which `items.length - 1` is -1 and
    // the window clamp below throws ArgumentError from inside an async gap.
    //
    // The probe-first change made this reachable on the ordinary path by
    // adding an await before the clamp, but the aliasing was always the bug:
    // indices computed from a list that another object may mutate are only
    // ever accidentally correct.
    items = List<PhotoItem>.of(items);

    // This call's generation. Every later navigation event -- and every folder
    // reload, via [reset] -- supersedes it, so the two awaits below re-check
    // this before acting on a window that may already be history.
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
    final tPrio = PerfLog.us;
    final wasInFlight = _loadingKeys.contains(selectedItemId);
    final wasCached = _cache.contains(selectedItemId);
    PerfLog.log(
      'preload.priority.begin|$selectedItemId'
      '|cached=$wasCached|inFlight=$wasInFlight',
    );
    await _ensurePayload(
      items[currentIndex],
      distance: 0,
      notifyLoaded: notifyLoaded,
    );
    // PERF-INSTRUMENTATION
    PerfLog.log(
      'preload.priority.end|$selectedItemId|dur=${PerfLog.us - tPrio}'
      '|nowCached=${_cache.contains(selectedItemId)}',
    );

    // Stale resume: a newer selection (or a folder reload) already owns the
    // scheduling state. The payload this pass produced is kept -- it is either
    // in the new retention window or was refused by the window check inside
    // _ensurePayload -- but nothing from here on may touch state that now
    // belongs to a different generation.
    if (generation != _previewGeneration) return;

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
    final probeFutures =
        <
          Future<
            ({
              PhotoItem item,
              int distance,
              VoidCallback? notifyLoaded,
              ProbeResult probe,
            })?
          >
        >[];
    for (final i in nearToFarOrder) {
      probeFutures.add(_probeWindowItem(items[i], distance: i - currentIndex));
    }
    final probeResults = await Future.wait(probeFutures);

    // Phase 2: route every probed item, in the same near-to-far order the
    // loop above walked. `_ensurePayload` performs its serial-lane enqueue
    // (if the probe says expensive) SYNCHRONOUSLY before its first await
    // when handed a `precomputedProbe`, so this loop's iteration order IS
    // the lane's start order -- restoring the property width 1 got for free
    // from serialisation alone.
    final pendingLoads = <Future<void>>[];
    for (final result in probeResults) {
      if (result == null) continue;
      pendingLoads.add(
        _ensurePayload(
          result.item,
          distance: result.distance,
          notifyLoaded: result.notifyLoaded,
          precomputedProbe: result.probe,
        ),
      );
    }
    await Future.wait(pendingLoads);
    PerfLog.log('preload.window.end|$selectedItemId'); // PERF-INSTRUMENTATION

    // Same check, after the window's awaits. This is the load-bearing one:
    // TierTwoScheduler.schedule CANCELS the debounce timer before rescheduling,
    // so a stale resume here does not merely add work for an abandoned
    // window -- it takes the full-size decode away from the item the user is
    // actually looking at.
    if (generation != _previewGeneration) return;

    _precacheTierOneWindow(items, currentIndex);
    _tierTwoScheduler.schedule(items, currentIndex, notifyLoaded);
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

    if (_loadingKeys.contains(id)) {
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
  _probeWindowItem(PhotoItem item, {required int distance}) async {
    final id = item.id;
    if (_earlyResolve(id, null)) return null;
    final file = item.bestFileToLoad;
    if (file == null) return null;
    final probed = await _scheduler.classify(
      id,
      file.path,
      longEdge: _longEdge,
    );
    return (item: item, distance: distance, notifyLoaded: null, probe: probed);
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

    // THE CLAIM, taken here and not after the probe (verdict 2026-08-30 fix A).
    // `_earlyResolve` above read `_loadingKeys`; taking the claim after the
    // `classify` await below left a suspension point between check and claim,
    // so two entrants for the same id both passed the check and both bought a
    // source load -- and the second `_cache.put` replaced the payload object,
    // orphaning the tier-1 ImageCache key (which is bytes identity). Every
    // exit below removes it again: the expensive-route hand-off, the probe's
    // catch, and the `finally`.
    _loadingKeys.add(id);

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
      // in `_loadingKeys` forever -- every later caller would park on a load
      // that will never land. Error propagation is unchanged.
      _loadingKeys.remove(id);
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
      _loadingKeys.remove(id);
      _enqueueSerialLoad(item, distance: distance, notifyLoaded: notifyLoaded);
      return;
    }

    final tCh = PerfLog.us; // PERF-INSTRUMENTATION
    // Set when the encode is handed to [_finishOffLane]: the `_loadingKeys`
    // claim then belongs to that continuation, not to this `finally`.
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

      // THE STAGE BOUNDARY. A real decode ran and an encode is owed, and this
      // call IS the lane's task body -- so return now and let the encode run
      // on its own stage. The lane slot is freed here; the `_loadingKeys`
      // claim is NOT (see [_finishOffLane]).
      if (onSerialLane && decode.pixels != null) {
        handedOff = true;
        unawaited(
          _finishOffLane(
            item,
            decode: decode,
            distance: distance,
            notifyLoaded: notifyLoaded,
            loadLongEdge: loadLongEdge,
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
      // A deferred outcome hands both the work and the `_loadingKeys` claim to
      // the lane; the `finally` below must not take the claim back off it.
      if (await _completeOutcome(
        item,
        outcome: outcome,
        distance: distance,
        notifyLoaded: notifyLoaded,
        onSerialLane: onSerialLane,
        loadLongEdge: loadLongEdge,
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
      if (!handedOff) _loadingKeys.remove(id);
    }
  }

  /// The encode half of an expensive load, run OFF the [DecodeLane].
  ///
  /// The lane slot was released when `_ensurePayload` returned, so the ~89ms
  /// encode no longer blocks the next decode. Two things must therefore be
  /// true here and are:
  ///
  ///   * `_loadingKeys` still holds [item]'s id -- released only in this
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
      _loadingKeys.remove(id);
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
  /// the `_loadingKeys` claim over with it (the deferred route below). The
  /// caller must then NOT release that claim in its own `finally`.
  Future<bool> _completeOutcome(
    PhotoItem item, {
    required SourceOutcome outcome,
    required int distance,
    required VoidCallback? notifyLoaded,
    required bool onSerialLane,
    required int loadLongEdge,
  }) async {
    final id = item.id;
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
      // Whoever produced it, the sidebar's waiters get their tile from THIS
      // payload -- never from a second decode of their own (D5 decision 2).
      _sidebar.onPayloadLanded(id, payload);
      if (onSerialLane) {
        // A serially landed payload gets its tier-1 ImageCache entry HERE,
        // not on "the next navigation pass": when the user has stopped
        // navigating there is no next pass, and the item would sit retained
        // with nothing decoded for it -- the very stall this ruling exists
        // to remove. Cheap items keep taking the batched route in
        // [_precacheTierOneWindow], which runs microseconds after their
        // parallel loads land anyway.
        _precacheTierOneFor(id, payload, distance: distance);
      }
    } else if (!outcome.deferred) {
      // Every source failed, including the legacy fallback. Mark it so the
      // view can say "unreadable" instead of spinning forever, and so no
      // later pass asks again. This is the load-bearing edge of design §3.4:
      // the ONLY new stranding risk in M3 is a failure that nobody records.
      _permanentMisses.add(id);
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
      _loadingKeys.remove(id);
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
        );
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
      priority: laneRankFor(distance),
      // `distance` is captured at enqueue time and becomes stale after
      // navigation. This is harmless: a navigation re-enqueue REPLACES this
      // body with a fresh distance, so stale distance only survives when the
      // item stays queued from its original enqueue — and the only consumer
      // of `distance` inside the body is _ensurePayload's deferred
      // re-enqueue rank, which the next navigation pass overwrites anyway.
      body: () async {
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
      exempt: distance == 0,
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
        exempt: i == currentIndex,
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
  Future<void> preloadThumbnails({
    required List<PhotoItem> items,
    required int startIdx,
    required int endIdx,
    required VoidCallback notifyLoaded,
  }) => _sidebar.preloadThumbnails(
    items: items,
    startIdx: startIdx,
    endIdx: endIdx,
    notifyLoaded: notifyLoaded,
  );
}
