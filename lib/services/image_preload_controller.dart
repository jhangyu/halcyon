import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/photo_item.dart';
import '../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import 'dng_decode_contract.dart';
import 'native_thumbnail_service.dart';
import 'photo_payload.dart';
import 'photo_payload_cache.dart';
import 'photo_source.dart';
import 'prefetch_scheduler.dart';
import 'raw_pixels_image.dart';

typedef ImageBytesLoader =
    Future<NativeImageResult> Function(
      String path, {
      required ImageRequestPurpose purpose,
    });

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
    required ImageBytesLoader imageLoader,
    DngFullDecoder? dngDecoder,
  }) : _source = PhotoSource(loader: imageLoader, dngDecoder: dngDecoder);

  final PhotoSource _source;
  final PhotoPayloadCache _cache = PhotoPayloadCache();
  final PrefetchScheduler _scheduler = PrefetchScheduler();

  final Map<String, Uint8List> _thumbCache = {};
  final Set<String> _loadingKeys = {};
  // Callbacks from callers who selected an item while its load was already in
  // flight (started by a previous preload pass). Flushed once the in-flight
  // load completes so the UI never strands on a permanent spinner.
  final Map<String, List<VoidCallback>> _pendingPreviewNotifies = {};

  // The current -3..+5 retention window. Async source completions re-check
  // this before writing, so a late arrival cannot resurrect an item the user
  // has already navigated away from.
  Set<String> _retentionIds = {};

  // Tier-1 (window-resolution) decode precache bookkeeping.
  int? _tierOneWidth;
  int? _tierOneHeight;
  final Map<String, Object> _tierOneKeys = {};

  // Tier-2 (full size) decode precache bookkeeping. Own window (+/-1), own key
  // namespace (distinct from tier-1's ResizeImageKey) and own eviction, so the
  // two tiers coexist without either clobbering the other's ImageCache entry
  // for the same item id.
  //
  // These maps are id-keyed, but the ImageCache entry they describe is keyed by
  // PAYLOAD OBJECT IDENTITY. When an item leaves the retention window and later
  // returns, it gets a NEW payload, so a stale id-keyed "ready" flag would
  // point at an ImageCache entry for a payload that is no longer current --
  // readiness must be re-derived at read time against the CURRENT payload
  // (round-2 review BLOCKER 1).
  Timer? _tierTwoDebounceTimer;
  // The ids the MOST RECENT tier-2 sweep was for. A source started by that
  // sweep finishes asynchronously, and by then the window may have moved; this
  // is what its completion re-checks itself against.
  Set<String> _tierTwoWindowIds = {};
  final Map<String, Object> _tierTwoKeys = {};
  // Serialises the debounced +/-1 loads. See [_enqueueTierTwoLoad].
  Future<void> _tierTwoQueue = Future<void>.value();
  final Map<String, SourcePayload> _tierTwoSources = {};
  final Set<String> _tierTwoReadyIds = {};

  // Items no source could produce anything for (corrupt/truncated/unsupported,
  // or a RAW decode failure whose legacy fallback also failed). Without this
  // the view cannot tell "not loaded yet" from "will never load" and spins
  // forever; it also stops every pass re-asking for an answer that cannot
  // change. Cleared only by [reset] (i.e. a folder reload).
  //
  final Set<String> _permanentMisses = {};

  // The SIDEBAR's permanent misses (design authority §2.2: the sidebar had no
  // negative cache at all, so a thumbnail that can never be produced was
  // re-requested on every sweep, forever -- invariant I8).
  //
  // Deliberately a SECOND CONTAINER rather than a second key shape inside
  // [_permanentMisses]. What I8 shares is the POLICY -- asked once, remembered
  // until the folder reloads -- not the container. Keying the sidebar's
  // entries as `thumb_<id>` inside the preview set is unsound: [PhotoItem.id]
  // is `basenameWithoutExtension` (supported_photo_formats.dart:44, used as
  // the grouping key at photo_library_scanner.dart:23), so ids are
  // user-controlled filenames, and a folder holding both `IMG_01.jpg` and
  // `thumb_IMG_01.jpg` makes one string mean two things -- the sidebar's
  // failure for the first is read back as a PREVIEW miss for the second,
  // which the view then calls unreadable although it never failed at
  // anything. No prefix or escape rescues that, because the id space is
  // unrestricted; two questions need two containers.
  //
  // Both sets are cleared by [reset]: THAT part is the shared policy.
  final Set<String> _thumbPermanentMisses = {};

  // id -> EXIF orientation, written by the content probe (and, only for files
  // the probe could not measure, by the bridge's rung-2 answer).
  //
  // This is what lets the debounced +/-1 pass hand `loadExpensive` an
  // orientation without a single further bridge or loader call: the same walk
  // that decided the rung already read IFD0 (invariant I6). Like the cost memo
  // it lives for the whole folder -- an item evicted from the retention window
  // and navigated back to must not have to buy its orientation twice -- so it
  // is cleared only by [reset].
  final Map<String, int> _exifOrientations = {};

  int _lastPreloadStart = -1;
  int _lastPreloadEnd = -1;
  Timer? _thumbnailDebounceTimer;
  // Bumped by every new thumbnail request and by [reset]. The running batch
  // carries the generation it started with and stops as soon as it no longer
  // matches, so a batch whose range is already stale (fast scroll, or a folder
  // reload that cleared _thumbCache underneath it) cannot keep spending
  // channel round-trips or write thumbnails for a list that is gone.
  int _thumbBatchGeneration = 0;

  // The PREVIEW path's own generation, bumped by every [preloadImages] call
  // and by [reset]. It is deliberately separate from _thumbBatchGeneration,
  // which counts sidebar batches: a running preview pass awaits its priority
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
  SourcePayload? payloadFor(String? id) => _cache.peek(id);

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

  Uint8List? thumbnailBytesFor(String id) => _thumbCache[id];

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

  /// Whether the full-size (tier-2) decode for [id] has COMPLETED and the
  /// resulting ImageCache entry is still resident **for the item's current
  /// payload**. A conjunction of two independent facts, both required
  /// (round-2 review BLOCKER 1 and BLOCKER 3 each came from having only one):
  ///   1. `_tierTwoReadyIds.contains(id)` -- the decode listener's onImage
  ///      callback fired, i.e. the decode actually finished. Without this,
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
  /// that keep those two blockers dead; it no longer needs one, because a
  /// pixel payload is now an ordinary cache citizen with an ordinary provider
  /// (design §4, invariant I3).
  bool isFullSizeReady(String id) {
    if (!_tierTwoReadyIds.contains(id)) return false;
    final key = _tierTwoKeys[id];
    if (key == null) return false;
    final decodedFor = _tierTwoSources[id];
    final current = _cache.peek(id);
    if (decodedFor == null || !identical(decodedFor, current)) return false;
    return PaintingBinding.instance.imageCache.containsKey(key);
  }

  void reset() {
    _cache.clear();
    _thumbCache.clear();
    _loadingKeys.clear();
    _pendingPreviewNotifies.clear();
    _retentionIds = {};
    _tierOneKeys.clear();
    _tierTwoDebounceTimer?.cancel();
    for (final key in _tierTwoKeys.values) {
      PaintingBinding.instance.imageCache.evict(key);
    }
    _tierTwoKeys.clear();
    _tierTwoSources.clear();
    _tierTwoReadyIds.clear();
    _scheduler.reset();
    _permanentMisses.clear();
    _thumbPermanentMisses.clear();
    _exifOrientations.clear();
    _lastPreloadStart = -1;
    _lastPreloadEnd = -1;
    _thumbnailDebounceTimer?.cancel();
    _thumbBatchGeneration++;
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
    _thumbnailDebounceTimer?.cancel();
    _tierTwoDebounceTimer?.cancel();
    for (final key in _tierOneKeys.values) {
      PaintingBinding.instance.imageCache.evict(key);
    }
    for (final key in _tierTwoKeys.values) {
      PaintingBinding.instance.imageCache.evict(key);
    }
    _tierOneKeys.clear();
    _tierTwoKeys.clear();
    _tierTwoSources.clear();
    _tierTwoReadyIds.clear();
    _retentionIds = {};
    _cache.clear();
    // Nothing else to do: no image is owned here. A source still in flight at
    // teardown resolves into a payload nobody reads and is collected -- it
    // cannot leak a ~50MB handle, because there is no handle.
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
    );
    _retentionIds = neededIds;
    for (final id in _cache.retainOnly(neededIds)) {
      _evictTierTwoEntry(id);
    }
    _selectedIdForPerf = selectedItemId; // PERF-INSTRUMENTATION

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

    final startIdx = (currentIndex - kRetentionBefore).clamp(
      0,
      items.length - 1,
    );
    final endIdx = (currentIndex + kRetentionAfter).clamp(0, items.length - 1);
    final pendingLoads = <Future<void>>[];
    for (var i = startIdx; i <= endIdx; i++) {
      pendingLoads.add(
        _ensurePayload(
          items[i],
          distance: (i - currentIndex).abs(),
          notifyLoaded: null,
        ),
      );
    }
    await Future.wait(pendingLoads);
    PerfLog.log('preload.window.end|$selectedItemId'); // PERF-INSTRUMENTATION

    // Same check, after the window's awaits. This is the load-bearing one:
    // _scheduleTierTwoDecode CANCELS the debounce timer before rescheduling,
    // so a stale resume here does not merely add work for an abandoned
    // window -- it takes the full-size decode away from the item the user is
    // actually looking at.
    if (generation != _previewGeneration) return;

    _precacheTierOneWindow(items, currentIndex);
    _scheduleTierTwoDecode(items, currentIndex, notifyLoaded);
  }

  String? _selectedIdForPerf; // PERF-INSTRUMENTATION

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
  void _scheduleTierTwoDecode(
    List<PhotoItem> items,
    int currentIndex,
    VoidCallback notifyLoaded,
  ) {
    _tierTwoDebounceTimer?.cancel();
    _tierTwoDebounceTimer = Timer(tierTwoNavigationDebounce, () {
      _decodeTierTwoWindow(items, currentIndex, notifyLoaded);
    });
  }

  // Tier-2 precache: decode current +/-kTierTwoRadius at full size once
  // navigation has paused, and start the expensive sources that the immediate
  // pass deferred. Both tiers coexist: this only evicts its own window's
  // ImageCache entries and never touches _tierOneKeys or the payload cache --
  // payload retention is the -3..+5 rule and belongs to preloadImages alone.
  //
  // The span here is kTierTwoRadius (2), NOT kExpensiveStartupRadius (1). They
  // were one constant before round 2, and separating them is what lets the
  // full-size window widen WITHOUT widening how far an expensive RAW source may
  // be started -- the loop below still asks the scheduler that question per
  // item, so a no-preview RAW at distance 2 is enqueued, refused, and left
  // without a payload rather than added to the sequential decode queue.
  void _decodeTierTwoWindow(
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
    final neededIds = <String>{
      for (var i = tierStart; i <= tierEnd; i++) items[i].id,
    };
    _tierTwoWindowIds = neededIds;

    for (var i = tierStart; i <= tierEnd; i++) {
      final item = items[i];
      final payload = _cache.peek(item.id);
      if (payload == null) {
        // Either not fetched yet, or measured expensive and deferred by the
        // immediate pass. This is the ONLY place an expensive source runs, and
        // it is reached only after 250ms of navigation quiet -- verbatim
        // today's RAW startup behaviour.
        //
        // Its tier-2 decode has to be chained onto the load rather than left
        // for "the next pass": if the user stops navigating here, there IS no
        // next pass, and readiness would never flip -- the payload would be
        // retained and the view would keep showing a spinner. The window
        // re-check is what keeps a late arrival from decoding for a position
        // the user has already left.
        _enqueueTierTwoLoad(
          item,
          distance: (i - currentIndex).abs(),
          notifyLoaded: notifyLoaded,
        );
        continue;
      }
      // Only skip if the ready flag was set for THIS payload -- if the item's
      // payload was replaced since the last decode (e.g. it briefly left the
      // retention window), the flag is stale and the decode must be redone
      // against the current object (round-2 review BLOCKER 1).
      final alreadyDecoded =
          _tierTwoReadyIds.contains(item.id) &&
          identical(_tierTwoSources[item.id], payload);
      if (alreadyDecoded) continue;
      _decodeFullSizeIntoImageCache(item.id, payload, notifyLoaded);
    }

    final staleIds = _tierTwoKeys.keys
        .where((id) => !neededIds.contains(id))
        .toList();
    for (final id in staleIds) {
      _evictTierTwoEntry(id);
    }
  }

  /// Runs the debounced +/-1 loads ONE AT A TIME.
  ///
  /// All three +/-1 items become eligible at the same instant when the frozen
  /// 250ms debounce fires. Starting them concurrently -- which is what an
  /// `unawaited(...)` per loop iteration did -- puts up to three native RAW
  /// decodes in flight at once, and a RAW decode saturates cores rather than
  /// waiting on IO, so three in parallel is slower per image AND makes the
  /// selected item (the one the user is actually looking at) contend with its
  /// two neighbours.
  ///
  /// NOTE, deliberately not a no-op refactor: serialising these changes
  /// LATENCY. The neighbours now land after the selected item instead of
  /// alongside it, so the +1 item's worst case is roughly the sum of the queue
  /// ahead of it rather than the max. That is the intended trade (user
  /// clarification: "no embedded JPEG -> sequential RAW decode"), and it is a
  /// stated behaviour change for the acceptance battery, not an equivalence.
  ///
  /// The debounce itself is untouched (Amendment 3 clause 3).
  void _enqueueTierTwoLoad(
    PhotoItem item, {
    required int distance,
    required VoidCallback notifyLoaded,
  }) {
    _tierTwoQueue = _tierTwoQueue.then((_) async {
      // Re-checked HERE, not only at enqueue time: by the time this item's turn
      // comes the user may have navigated away, and decoding for a position
      // nobody is looking at is exactly what the queue exists to prevent.
      if (!_tierTwoWindowIds.contains(item.id)) return;
      await _ensurePayload(
        item,
        distance: distance,
        notifyLoaded: notifyLoaded,
        allowExpensive: true,
      );
      // The tier-2 decode is chained onto the load rather than left for "the
      // next pass": if the user stops navigating here there IS no next pass,
      // and readiness would never flip -- the payload would be retained and
      // the view would keep showing a spinner.
      final landed = _cache.peek(item.id);
      if (landed == null || !_tierTwoWindowIds.contains(item.id)) return;
      _decodeFullSizeIntoImageCache(item.id, landed, notifyLoaded);
    }).catchError((Object _) {
      // One item's failure must not wedge the queue for the rest of the
      // session. _ensurePayload already records real failures as permanent
      // misses; this only keeps the chain runnable.
    });
    unawaited(_tierTwoQueue);
  }

  /// Produces and retains [item]'s payload if it is not retained already.
  ///
  /// [distance] is how many items away from the selection this is; it decides
  /// which rung applies. [allowExpensive] is false on the immediate pass and
  /// true only from the debounced +/-1 sweep.
  Future<void> _ensurePayload(
    PhotoItem item, {
    required int distance,
    required VoidCallback? notifyLoaded,
    bool allowExpensive = false,
  }) async {
    final id = item.id;
    if (_cache.contains(id)) {
      // PERF-INSTRUMENTATION
      PerfLog.log(
        'loadPreview.skip|$id|cached=true|inFlight=false'
        '|isSelected=${id == _selectedIdForPerf}',
      );
      return;
    }

    // An answer that cannot change: do not re-ask any source for it.
    if (_permanentMisses.contains(id)) {
      notifyLoaded?.call();
      return;
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
        '|isSelected=${id == _selectedIdForPerf}',
      );
      return;
    }

    final file = item.bestFileToLoad;
    if (file == null) return;

    // CONTENT PROBE FIRST, for every item at every distance (user Amendment 3
    // clause 2). The probe is what decides the rung, so anything it does not
    // see gets scheduled on the bridge's say-so instead -- and the bridge is
    // reached by making the very call the rung exists to avoid.
    //
    // An earlier revision skipped the probe for the selected item and its
    // immediate neighbours, on the grounds that they were about to ask the
    // bridge anyway and the JPEG hot path must cost no Dart CPU. That is the
    // location-dependent classification the user rejected verbatim, and it was
    // the mechanical cause of a no-preview DNG at distance 0 or 1 burning a
    // bridge round trip before its rung was known. The price of the correction
    // is one bounded open (2 bytes for a JPEG, design §5's hot path intact).
    //
    // The rung gate below is unchanged: an item MEASURED expensive and outside
    // +/-1 is not touched at all -- no decode, no bridge round trip. That is
    // where the exactly-once guarantee lives (invariant I6).
    final probed = await _scheduler.classify(id, file.path, longEdge: _longEdge);
    final cost = probed.cost;
    // First writer wins, and after the change above the probe is the first
    // writer whenever it was conclusive. The bridge's orientation (below)
    // survives only as the A-§2 rung-2 fallback, for files the probe could not
    // measure at all.
    final probedOrientation = probed.exifOrientation;
    if (probedOrientation != null) {
      _exifOrientations.putIfAbsent(id, () => probedOrientation);
    }
    if (cost == SourceCost.expensive &&
        !(allowExpensive &&
            _scheduler.allowsExpensiveWork(distance: distance))) {
      // Already measured expensive, and this pass is not allowed to do
      // expensive work: asking the bridge again would be a channel round trip
      // for an answer that cannot change (invariant I6).
      return;
    }

    _loadingKeys.add(id);
    final tCh = PerfLog.us; // PERF-INSTRUMENTATION
    try {
      final canDoExpensive =
          allowExpensive && _scheduler.allowsExpensiveWork(distance: distance);
      final knownOrientation = _exifOrientations[id];
      final outcome = canDoExpensive && knownOrientation != null
          ? await _source.loadExpensive(
              file.path,
              longEdge: _longEdge,
              exifOrientation: knownOrientation,
            )
          : await _source.load(
              file.path,
              longEdge: _longEdge,
              allowExpensive: canDoExpensive,
            );
      _scheduler.observe(id, outcome.observedCost);
      // Rung-2 only: reached when the probe could not measure the file, so the
      // bridge answer is the sole orientation available (frozen contract A-§2).
      if (outcome.exifOrientation != null) {
        _exifOrientations.putIfAbsent(id, () => outcome.exifOrientation!);
      }
      final payload = outcome.payload;
      // PERF-INSTRUMENTATION
      PerfLog.log(
        'channel.preview|$id|bytes=${payload?.byteCost ?? -1}'
        '|roundtrip=${PerfLog.us - tCh}|notify=${notifyLoaded != null}'
        '|isSelected=${id == _selectedIdForPerf}',
      );

      if (payload != null) {
        // The orientation memo deliberately SURVIVES a successful load. It is
        // a property of the file, not of this attempt; dropping it here would
        // make an item that leaves the retention window and comes back buy it
        // again from the bridge, which is the round trip I6 forbids.
        if (!_retentionIds.contains(id)) return;
        _cache.put(id, payload);
      } else if (!outcome.deferred) {
        // Every source failed, including the legacy fallback. Mark it so the
        // view can say "unreadable" instead of spinning forever, and so no
        // later pass asks again. This is the load-bearing edge of design §3.4:
        // the ONLY new stranding risk in M3 is a failure that nobody records.
        _permanentMisses.add(id);
      }
      // A deferred item is the one case with nothing to report yet: the
      // debounced +/-1 pass owns it and will notify when its payload lands.
      // That spinner is bounded by tierTwoNavigationDebounce, which is today's
      // measured behaviour for a preview-less DNG (invariant T1).
      final resolved = payload != null || _permanentMisses.contains(id);
      final pending = _pendingPreviewNotifies.remove(id);
      if (resolved) {
        notifyLoaded?.call();
        for (final cb in pending ?? const <VoidCallback>[]) {
          cb();
        }
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
      _loadingKeys.remove(id);
    }
  }

  void _decodeFullSizeIntoImageCache(
    String id,
    SourcePayload payload,
    VoidCallback notifyLoaded,
  ) {
    final provider = _fullSizeProviderForPayload(payload);
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener((image, synchronousCall) {
      stream.removeListener(listener);
      _tierTwoReadyIds.add(id);
      notifyLoaded();
    }, onError: (error, stackTrace) => stream.removeListener(listener));
    stream.addListener(listener);
    provider.obtainKey(const ImageConfiguration()).then((key) {
      _tierTwoKeys[id] = key;
      _tierTwoSources[id] = payload;
    });
  }

  // Removes id's tier-2 bookkeeping and evicts its ImageCache entry (if any).
  // Never touches _tierOneKeys or the payload cache -- tier-1 and retention
  // have their own, separate lifecycles.
  //
  // Note what is NOT here any more: no dispose, no in-flight marker to clear,
  // no evict-before-dispose ordering. Evicting an ImageCache entry can no
  // longer destroy anything the pipeline still needs, because what the
  // pipeline keeps is the payload, and the payload is bytes.
  void _evictTierTwoEntry(String id) {
    final key = _tierTwoKeys.remove(id);
    _tierTwoSources.remove(id);
    _tierTwoReadyIds.remove(id);
    if (key != null) {
      PaintingBinding.instance.imageCache.evict(key);
    }
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
  // payload instead of fetching one. That is what keeps the widened span from
  // smuggling an expensive RAW decode outside the +/-1 startup radius (the
  // scheduler, not this loop, decides what may be started).
  void _precacheTierOneWindow(List<PhotoItem> items, int currentIndex) {
    final width = _tierOneWidth;
    final height = _tierOneHeight;
    if (width == null || height == null) return;

    final tierStart = (currentIndex - kRetentionBefore).clamp(
      0,
      items.length - 1,
    );
    final tierEnd = (currentIndex + kRetentionAfter).clamp(
      0,
      items.length - 1,
    );
    final neededIds = <String>{};

    for (var i = tierStart; i <= tierEnd; i++) {
      final item = items[i];
      final payload = _cache.peek(item.id);
      if (payload == null) continue; // not loaded yet; retried on next pass
      neededIds.add(item.id);
      _decodeIntoImageCache(
        item.id,
        _tierOneProviderForPayload(payload, width: width, height: height),
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

  void _decodeIntoImageCache(String id, ImageProvider provider) {
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) => stream.removeListener(listener),
      onError: (error, stackTrace) => stream.removeListener(listener),
    );
    stream.addListener(listener);
    provider
        .obtainKey(const ImageConfiguration())
        .then((key) => _tierOneKeys[id] = key);
  }

  /// Loads sidebar thumbnails for the VISIBLE range [startIdx]..[endIdx],
  /// plus [thumbnailPrefetchMargin] rows of prefetch on each side.
  ///
  /// The caller passes what it can actually see (the sidebar reports the index
  /// range its `itemBuilder` built this frame); the margin is this class's
  /// business, so the fetch ORDER can put every visible row ahead of every
  /// prefetched one. That ordering is the point: the range is up to 41 rows and
  /// the loop is sequential, so a start-to-end sweep would spend 20 round-trips
  /// on off-screen rows above the viewport before touching a single row the
  /// user is looking at.
  Future<void> preloadThumbnails({
    required List<PhotoItem> items,
    required int startIdx,
    required int endIdx,
    required VoidCallback notifyLoaded,
  }) async {
    if (items.isEmpty) return;

    final safeStart = startIdx.clamp(0, items.length - 1);
    final safeEnd = endIdx.clamp(0, items.length - 1);

    if (_lastPreloadStart == safeStart && _lastPreloadEnd == safeEnd) return;
    _lastPreloadStart = safeStart;
    _lastPreloadEnd = safeEnd;

    // Supersede any batch still running for the previous range.
    final generation = ++_thumbBatchGeneration;

    _thumbnailDebounceTimer?.cancel();
    _thumbnailDebounceTimer = Timer(
      const Duration(milliseconds: 100),
      () async {
        // Visible first, top to bottom; then outward from the viewport edges,
        // one row below then one row above, so the direction the user is more
        // likely to scroll is never starved by the other side.
        final order = <int>[];
        for (var i = safeStart; i <= safeEnd; i++) {
          order.add(i);
        }
        for (var d = 1; d <= thumbnailPrefetchMargin; d++) {
          if (safeEnd + d < items.length) order.add(safeEnd + d);
          if (safeStart - d >= 0) order.add(safeStart - d);
        }

        final neededThumbIds = {for (final i in order) items[i].id};
        _thumbCache.removeWhere((key, _) => !neededThumbIds.contains(key));

        for (final index in order) {
          // A newer range (or a folder reload) arrived while we were awaiting;
          // everything from here on is for a viewport that no longer exists.
          if (generation != _thumbBatchGeneration) return;

          final item = items[index];
          final id = item.id;
          final loadingKey = 'thumb_$id';
          // An in-memory Set lookup and nothing more -- the sidebar's negative
          // cache costs the hot path one hash probe per row and saves a
          // channel round trip per sweep for every file that can never produce
          // a thumbnail. Keyed by the bare id, in the sidebar's OWN set: see
          // [_thumbPermanentMisses] for why it cannot live in the preview set
          // under a prefix.
          if (_thumbCache.containsKey(id) ||
              _loadingKeys.contains(loadingKey) ||
              _thumbPermanentMisses.contains(id)) {
            continue;
          }

          final file = item.bestFileToLoad;
          if (file == null) continue;

          _loadingKeys.add(loadingKey);
          try {
            // Native only ever emits the raw-decode signal for purpose ==
            // preview, so for thumbnails anything that is not bytes is simply
            // "no thumbnail", exactly as null was before.
            final result = await _source.loader(
              file.path,
              purpose: ImageRequestPurpose.sidebarThumbnail,
            );
            if (generation != _thumbBatchGeneration) return;
            if (result is NativeImageBytes) {
              _thumbCache[id] = result.bytes;
              notifyLoaded();
            } else {
              // Native only ever emits the raw-decode signal for purpose ==
              // preview, so anything that is not bytes here means no source
              // produced a thumbnail -- an answer that cannot change until the
              // folder is reloaded (which is what clears the set).
              _thumbPermanentMisses.add(id);
            }
          } catch (_) {
            // The loader THREW instead of returning a NativeImageFailure --
            // an unconverted PlatformException/MissingPluginException, or a
            // native TypeError on a non-Uint8List channel reply (round-1
            // parking-lot PL-1/PL-2/PL-10). Treat it exactly like a non-bytes
            // result: an answer that cannot change until the folder reloads,
            // so no later sweep re-asks. Without this the exception used to
            // unwind the whole `for` loop, silently dropping every remaining
            // item in this sweep, on top of leaking `loadingKey` for the rest
            // of the session (the finally below is what fixes that half).
            if (generation == _thumbBatchGeneration) {
              _thumbPermanentMisses.add(id);
            }
          } finally {
            _loadingKeys.remove(loadingKey);
          }
        }
      },
    );
  }
}

typedef VoidCallback = void Function();
