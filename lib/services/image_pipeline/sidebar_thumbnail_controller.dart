import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/photo_item.dart';
import 'decode_lane.dart';
import 'lane_priority.dart';
import 'derive_queue.dart';
import 'image_preload_controller.dart' show thumbnailPrefetchMargin;
import 'photo_payload.dart';
import 'thumbnail_derivation.dart';

/// Everything the sidebar thumbnail strip owns.
///
/// Extracted from [ImagePreloadController] 2026-09-03. The shape is AD-028's:
/// collaborators arrive as CLOSURES, never as objects. This unit therefore
/// holds no payload cache, no photo source, no prefetch scheduler and no
/// reference to the controller -- so retention policy, source selection and
/// rung policy each keep exactly one owner, and the sidebar can be unit-tested
/// with a handful of closures instead of a pipeline.
///
/// What deliberately did NOT move: the tier-1/tier-2 provider factories. AD-028
/// states the reason -- the two factories sitting side by side in the controller
/// IS the declaration that one payload identity means one ImageCache key, and a
/// second place that builds providers is a second place that decides cache keys.
class SidebarThumbnailController {
  SidebarThumbnailController({
    required SourcePayload? Function(String id) peekPayload,
    required bool Function(String id) hasPayload,
    required bool Function(String id) isPreviewPermanentMiss,
    required DecodeLane decodeLane,
    required Future<void> Function(PhotoItem item) ensurePayload,
    required Set<String> Function() retentionIds,
    required VoidCallback republishEvictionPriority,
  }) : _peekPayload = peekPayload,
       _hasPayload = hasPayload,
       _isPreviewPermanentMiss = isPreviewPermanentMiss,
       _decodeLane = decodeLane,
       _ensurePayload = ensurePayload,
       _retentionIds = retentionIds,
       _republishEvictionPriority = republishEvictionPriority;

  final SourcePayload? Function(String id) _peekPayload;
  final bool Function(String id) _hasPayload;
  final bool Function(String id) _isPreviewPermanentMiss;
  final DecodeLane _decodeLane;
  final Future<void> Function(PhotoItem item) _ensurePayload;
  final Set<String> Function() _retentionIds;
  final VoidCallback _republishEvictionPriority;

  // A SUM TYPE, not bytes: the JPG / embedded-preview path stores the encoded
  // bitstream it already had, and the RAW-decode path stores oriented,
  // 200px-capped RGBA. The RAW path used to JPEG-re-encode purely to satisfy
  // this map's old `Uint8List` value type -- a sidebar-exclusive step that had
  // no counterpart on the preview path and was the primary suspect for the
  // Windows blank-tile bug (root-cause R2.3.1 step 6).
  final Map<String, SourcePayload> _cache = {};

  // Rows the sidebar wants a tile for and whose payload has not landed yet.
  //
  // The sidebar is a CONSUMER now (USER RULING 2026-08-30, contract D5): it
  // registers interest instead of producing pixels of its own, and
  // [onPayloadLanded] converts a landed payload into a tile. Pruned in the
  // same statement that prunes `_cache`, so a waiter cannot outlive its
  // viewport.
  final Set<String> _waiters = {};

  // The sidebar's repaint callback, parked by the sweep so an asynchronous
  // payload-landed derivation can report a tile that no sweep is awaiting.
  VoidCallback? _notify;

  // Ids the SIDEBAR put on the lane, for assertions. Cleared by [reset].
  final Set<String> _enqueuedIds = {};

  /// Sidebar-thumbnail loads in flight, keyed by BARE photo id.
  ///
  /// A separate set from the controller's detail-path `_loadingKeys`, not a
  /// `'thumb_$id'` prefix inside it: one set holding two key shapes is exactly
  /// the collision class the controller warns about, and a prefixed key
  /// silently answers `contains(id)` with false while a bare id silently
  /// answers a thumbnail query with true.
  final Set<String> _loadingKeys = {};

  // The SIDEBAR's demand: the visible range +/- thumbnailPrefetchMargin.
  //
  // USER RULING 2026-08-30 (contract D5, "捲動亦填充 payload"): scrolling fills
  // the payload cache too, so the sidebar is now a second contributor to WHAT
  // IS RETAINED. It is deliberately NOT a second budget or a second eviction
  // rule -- D4's "one retention rule for every file type" is untouched; only
  // the membership question gained a contributor.
  Set<String> _wantedIds = {};

  // Near-to-far eviction order, the sidebar's half. Kept split by contributor
  // for the same reason the sets are: republished whenever either changes.
  List<String> _priorityIds = [];

  // The SIDEBAR's permanent misses (design authority §2.2: the sidebar had no
  // negative cache at all, so a thumbnail that can never be produced was
  // re-requested on every sweep, forever -- invariant I8).
  //
  // Deliberately a SECOND CONTAINER rather than a second key shape inside the
  // controller's preview `_permanentMisses`. What I8 shares is the POLICY --
  // asked once, remembered until the folder reloads -- not the container.
  // Keying the sidebar's entries as `thumb_<id>` inside the preview set is
  // unsound: [PhotoItem.id] is `basenameWithoutExtension`
  // (supported_photo_formats.dart:44, used as the grouping key at
  // photo_library_scanner.dart:23), so ids are user-controlled filenames, and a
  // folder holding both `IMG_01.jpg` and `thumb_IMG_01.jpg` makes one string
  // mean two things -- the sidebar's failure for the first is read back as a
  // PREVIEW miss for the second, which the view then calls unreadable although
  // it never failed at anything. No prefix or escape rescues that, because the
  // id space is unrestricted; two questions need two containers.
  //
  // Both sets are cleared by reset: THAT part is the shared policy.
  final Set<String> _permanentMisses = {};

  int _lastPreloadStart = -1;
  int _lastPreloadEnd = -1;
  Timer? _debounceTimer;

  // Bounds concurrent [_deriveTile] runs fired from [onPayloadLanded] (Phase 2,
  // async-pipeline-refactor-plan.md §3). A burst of landings used to fire
  // `_deriveTile` unawaited per landing -- unbounded concurrency on the UI
  // isolate, resolved in arbitrary arrival order. The queue is priority-
  // ordered by [_rowDistanceById] so a visible-centre landing is derived
  // before a margin landing even if the margin one arrived first. The SWEEP
  // path (`preloadThumbnails` RULE 1) is untouched -- it is already
  // sequential and keeps its inline await (D5 rule 1, §8-D2).
  final DeriveQueue _deriveQueue = DeriveQueue(width: 2);

  // This sweep's row distance per id, from [_rowDistance] -- the SAME
  // distance function `_enqueueSidebarPayload` uses for lane priority, reused
  // here (not a second distance scheme) so [onPayloadLanded] can rank a
  // landed id without recomputing its position. Replaced wholesale by every
  // sweep; a landing for an id outside the latest sweep's `order` (should not
  // happen -- see [onPayloadLanded]) falls back to [_fallbackLandedPriority].
  Map<String, int> _rowDistanceById = {};
  // Bumped by every new thumbnail request and by [reset]. The running batch
  // carries the generation it started with and stops as soon as it no longer
  // matches, so a batch whose range is already stale (fast scroll, or a folder
  // reload that cleared `_cache` underneath it) cannot keep spending
  // channel round-trips or write thumbnails for a list that is gone.
  int _batchGeneration = 0;

  /// The retention union's SIDEBAR contributor (image_preload_controller.dart
  /// `_retentionIds`). Published, never a second stored copy in the controller.
  Set<String> get wantedIds => _wantedIds;

  /// The sidebar half of the near-to-far eviction order.
  List<String> get priorityIds => _priorityIds;

  SourcePayload? thumbnailPayloadFor(String id) => _cache[id];

  int get cacheLength => _cache.length;

  /// Sum of `byteCost` over the sidebar cache. Exists so INV-MEM is an
  /// asserted acceptance condition (TC-374) rather than an estimate in prose.
  int get cacheByteCost => _cache.values.fold(0, (sum, p) => sum + p.byteCost);

  Set<String> get permanentMisses => Set<String>.unmodifiable(_permanentMisses);

  Set<String> get enqueuedIds => Set<String>.unmodifiable(_enqueuedIds);

  /// Test-only window into the derivation queue's state, so a test can assert
  /// what would run next without racing the queue's own microtask pump.
  @visibleForTesting
  DeriveQueue get debugDeriveQueue => _deriveQueue;

  /// Test-only: this sweep's row distance for [id], or null if [id] was not
  /// part of the latest sweep's order.
  @visibleForTesting
  int? debugRowDistanceFor(String id) => _rowDistanceById[id];

  /// A payload that can NEVER be produced is also a tile that can never be
  /// produced. Without this the sidebar would wait forever on a file the
  /// preview path has already given up on -- the sidebar's own negative cache
  /// exists precisely so a hopeless row is asked about once (invariant I8).
  void onPayloadMiss(String id) {
    _waiters.remove(id);
    _permanentMisses.add(id);
  }

  /// One line per swallowed sidebar failure. Console output, NOT user-facing
  /// UI -- the 2026-08-26 "no failure UI" ruling stands, and this is inside
  /// it. Permanent, not a temporary debug aid: its absence is what turned the
  /// Windows blank-tile bug into a two-round static-tracing investigation.
  /// Volume is one line per id per folder load, bounded by [_permanentMisses].
  void logFailure(String id, String stage, Object error) {
    final message = error.toString();
    debugPrint(
      'sidebar.thumb|id=$id|stage=$stage|err=${error.runtimeType}|'
      'msg=${message.substring(0, message.length.clamp(0, 200))}',
    );
  }

  /// THE point where "one decode serves both" becomes true.
  ///
  /// Called immediately after every payload cache put, whoever produced the
  /// payload. Derivation is cheap (a sized re-decode of bytes already
  /// resident) but it is still async, so both staleness guards apply: the
  /// batch generation is captured BEFORE the first await, and the id must
  /// still be wanted when the result comes back. Dropping either one
  /// reintroduces the stale-viewport write this code has been patched for
  /// twice.
  void onPayloadLanded(String id, SourcePayload payload) {
    if (!_waiters.remove(id)) return;
    if (_cache.containsKey(id)) return;
    final generation = _batchGeneration;
    final priority = _rowDistanceById[id] ?? _fallbackLandedPriority();
    unawaited(
      _deriveQueue.submit(
        priority,
        () => _deriveTile(
          id,
          payload,
          generation,
          checkPayloadIdentity: true,
          claimLoadingKey: false,
          catchDeriveErrors: false,
          notifyLoaded: null,
        ),
      ),
    );
  }

  /// Used only when a landed id has no entry in [_rowDistanceById] -- every id
  /// that can reach [onPayloadLanded] was added to [_waiters] from the same
  /// sweep's `order` list that populates the map, so this is a defensive
  /// fallback, not the expected path. Ranks after every distance a real sweep
  /// can produce (see [_marginDistanceBase]).
  int _fallbackLandedPriority() =>
      _marginDistanceBase(_lastPreloadStart, _lastPreloadEnd) +
      thumbnailPrefetchMargin +
      1;

  /// The ONE derive-and-publish body, merged 2026-09-03 from the two copies
  /// that had drifted apart: [onPayloadLanded]'s async arm and
  /// [preloadThumbnails]' RULE 1 synchronous arm.
  ///
  /// The three flags are the only differences the two call sites ever had:
  ///
  /// * [checkPayloadIdentity] — the ASYNC path only. It awaited a derivation of
  ///   a payload that may since have been replaced in the cache, so it re-checks
  ///   `identical(peek(id), payload)` (D5). The sync path read the payload out
  ///   of the cache in the same turn and has nothing to re-check against.
  /// * [claimLoadingKey] — the SYNC path only. The sweep can revisit the same id
  ///   within one batch, so it claims the id in `_loadingKeys` and releases it in
  ///   a `finally`. The async path is driven by a one-shot waiter removal, which
  ///   already excludes a second entry.
  /// * [catchDeriveErrors] — the SYNC path only. A throwing derivation there is
  ///   logged (`stage=derive`) and the sweep continues to the next row; it is
  ///   never a permanent miss, because a later payload may derive fine. On the
  ///   async path the throw lands in an unawaited future, exactly as before.
  ///
  /// [notifyLoaded] is the sweep's callback on the sync path; the async path
  /// passes null and the parked [_notify] is used instead — a payload landing
  /// after the sweep returned still has to repaint the sidebar.
  ///
  /// Returns true when a tile was written.
  Future<bool> _deriveTile(
    String id,
    SourcePayload payload,
    int generation, {
    required bool checkPayloadIdentity,
    required bool claimLoadingKey,
    required bool catchDeriveErrors,
    required VoidCallback? notifyLoaded,
  }) async {
    if (claimLoadingKey) _loadingKeys.add(id);
    try {
      final derived = await deriveThumbnailPayload(payload);
      // A null derivation is NOT a permanent miss: the payload may be replaced
      // by a better one later, and a permanent miss is unrecoverable until the
      // folder reloads. Amendment E-H1(a): put the id BACK on the waiter list
      // so a later landing retries it, rather than silently dropping the row.
      if (derived == null) {
        if (_wantedIds.contains(id)) _waiters.add(id);
        return false;
      }
      if (generation != _batchGeneration) return false;
      if (!_wantedIds.contains(id)) return false;
      if (checkPayloadIdentity && !identical(_peekPayload(id), payload)) {
        return false;
      }
      _cache[id] = derived;
      (notifyLoaded ?? _notify)?.call();
      return true;
    } catch (e) {
      if (!catchDeriveErrors) rethrow;
      // Derivation is not a loader failure and must not be labelled one; it is
      // also not permanent -- a later payload may derive.
      logFailure(id, 'derive', e);
      return false;
    } finally {
      if (claimLoadingKey) _loadingKeys.remove(id);
    }
  }

  /// Distance from the visible viewport used to rank rows within the DERIVE
  /// queue (PHASE 4: the LANE takes its ranking from [sidebarPriorityFor]
  /// instead; this single-band total order is still what the derive queue
  /// wants).
  ///
  /// Two-part, fixed 2026-09-06 (contract D1): a row inside the visible range
  /// `[safeStart, safeEnd]` ranks by distance from the visible CENTER; a
  /// margin row (prefetch only, never on screen) ranks by [_marginDistanceBase]
  /// (itself derived from the visible span so it is always strictly larger
  /// than any in-range distance) plus its distance from the nearest visible
  /// edge. This guarantees every visible row outranks every margin row,
  /// which the old `(index - safeStart).abs()` formula did not: it measured
  /// from the TOP of the range with no floor for margin rows, so a margin row
  /// a few slots above the viewport could outrank a visible row deep in a
  /// tall visible range.
  static int _rowDistance({
    required int index,
    required int safeStart,
    required int safeEnd,
  }) {
    if (index >= safeStart && index <= safeEnd) {
      final center = (safeStart + safeEnd) ~/ 2;
      return (index - center).abs();
    }
    final marginBase = _marginDistanceBase(safeStart, safeEnd);
    final edgeDistance = index < safeStart
        ? safeStart - index
        : index - safeEnd;
    return marginBase + edgeDistance;
  }

  /// Strictly greater than any possible in-range distance from
  /// `(safeStart + safeEnd) ~/ 2`, which is bounded by the visible span
  /// itself (`safeEnd - safeStart`). Adding 1 to that span is therefore
  /// sufficient regardless of how wide the visible range is.
  static int _marginDistanceBase(int safeStart, int safeEnd) =>
      (safeEnd - safeStart) + 1;

  /// Asks the lane to produce [item]'s payload on the SIDEBAR's behalf.
  ///
  /// [priority] comes from [sidebarPriorityFor] (PHASE 4): visible rows land
  /// in the P3 band ranked by distance from the visible centre, margin rows in
  /// the P4 band ranked by distance from the nearest visible edge.
  ///
  /// D1's synthetic `marginDistanceBase` offset is no longer what separates
  /// the two classes ON THE LANE -- the band boundary is, and unlike the
  /// offset it cannot be out-run by a tall viewport. The offset survives in
  /// [_rowDistance] because the DERIVE queue is a different queue with a
  /// single band, where a within-sidebar total order is exactly what is
  /// wanted.
  ///
  /// The body re-checks the retention union when its TURN comes, not when it
  /// is queued (invariant I4): a row scrolled past before its turn does no
  /// work at all. Nothing is cancellable mid-body -- no FFI decode is -- so
  /// "cancellation" here is exactly pending-entry replacement plus this
  /// re-check, the same shape the controller's `_enqueueSerialLoad` uses.
  void _enqueueSidebarPayload(PhotoItem item, {required int priority}) {
    final id = item.id;
    _enqueuedIds.add(id);
    _decodeLane.enqueue(
      (LaneTaskKind.payload, id),
      priority: priority,
      body: () async {
        if (!_retentionIds().contains(id)) return;
        if (_hasPayload(id)) return;
        try {
          await _ensurePayload(item);
        } catch (e) {
          // A producer that THROWS (an unconverted PlatformException, a
          // MissingPluginException, a decoder that blew up) is NOT recorded as
          // a permanent miss by the payload producer: it rethrows, preserving
          // the preview path's error propagation, and the lane then swallows
          // the exception to stay runnable. Without this arm the row would end
          // the body with no payload AND no miss, so every later sweep would
          // re-enqueue it and re-ask a question whose answer cannot change --
          // invariant I8's forever-loop, which the deleted sweep's own
          // try/catch used to prevent (M6-PL1).
          //
          // Only the SIDEBAR's negative cache is written. The preview path's
          // policy for a throwing source is deliberately left exactly as it
          // was; widening it is a separate decision with its own blast radius.
          logFailure(id, 'produce', e);
          onPayloadMiss(id);
        }
      },
    );
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
  ///
  /// **The returned Future completes when the synchronous sweep has been
  /// ISSUED, not when every thumbnail has landed.** Rows fetched behind the
  /// debounce complete afterwards and report through [notifyLoaded]. Callers
  /// that `await` this get "the sweep is scheduled", never "the sidebar is
  /// fully painted"; awaiting it in a test and then asserting on bytes is a
  /// race, not a check.
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
    final generation = ++_batchGeneration;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 100), () async {
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

      _wantedIds = {for (final i in order) items[i].id};
      _priorityIds = [for (final i in order) items[i].id];
      // Populated for EVERY id in this sweep's order, not only the ones that
      // end up waiting for a producer: a payload can land (via the preview
      // path, another sidebar-adjacent producer, etc.) for any of them, and
      // [onPayloadLanded] needs a distance the moment that happens.
      _rowDistanceById = {
        for (final i in order)
          items[i].id: _rowDistance(
            index: i,
            safeStart: safeStart,
            safeEnd: safeEnd,
          ),
      };
      _republishEvictionPriority();
      _cache.removeWhere((key, _) => !_wantedIds.contains(key));
      // A waiter cannot outlive its viewport: pruned in the same statement
      // that prunes the tile cache, so [onPayloadLanded] can never write a
      // tile for a row that scrolled away.
      _waiters.removeWhere((key) => !_wantedIds.contains(key));
      // Parked once per sweep: a payload landing AFTER this sweep returns
      // still has to repaint the sidebar, and no sweep is awaiting it.
      _notify = notifyLoaded;

      for (final index in order) {
        // A newer range (or a folder reload) arrived while we were awaiting;
        // everything from here on is for a viewport that no longer exists.
        if (generation != _batchGeneration) return;

        final item = items[index];
        final id = item.id;
        // An in-memory Set lookup and nothing more -- the sidebar's negative
        // cache costs the hot path one hash probe per row. Keyed by the bare
        // id, in the sidebar's OWN set: see [_permanentMisses] for why it
        // cannot live in the preview set under a prefix.
        if (_cache.containsKey(id) ||
            _loadingKeys.contains(id) ||
            _permanentMisses.contains(id)) {
          continue;
        }
        // An answer that cannot change: the preview path already proved this
        // file produces nothing.
        if (_isPreviewPermanentMiss(id)) {
          _permanentMisses.add(id);
          continue;
        }
        if (item.bestFileToLoad == null) continue;

        final payload = _peekPayload(id);
        if (payload != null) {
          // RULE 1 -- the payload is already here. Derive and go: zero
          // decodes, zero file opens, zero loader round trips. This is the
          // whole of D5 decision 2 on the synchronous path.
          final wrote = await _deriveTile(
            id,
            payload,
            generation,
            checkPayloadIdentity: false,
            claimLoadingKey: true,
            catchDeriveErrors: true,
            notifyLoaded: notifyLoaded,
          );
          if (!wrote && generation != _batchGeneration) return;
          continue;
        }

        // RULE 2 -- no payload yet. Register interest either way; the
        // payload-landed hook turns whichever producer wins into a tile.
        _waiters.add(id);
        // RULE 3 -- (re-)enqueue at this sweep's priority, UNLESS the key is
        // currently pending at a NAVIGATION priority (< kSidebarPayloadPriorityBase).
        //
        // PHASE 4 note: this comparison still separates exactly the two cases
        // it always did, on the new band table. The lane key here is
        // (payload, id). THREE producers write that key -- the controller's
        // navigation pass, the tier-2 scheduler's catch-up sweep, and this
        // sidebar -- but the first two both enqueue in the NAVIGATION bands
        // (P1/P2, < 2000) via `navigationPriorityFor`, so from this
        // predicate's point of view they are one case: "not the sidebar".
        // (An earlier revision of this comment claimed navigation was the
        // only other producer; the tier-2 catch-up path was missed by the
        // Phase 4 rebase and is fixed in the same commit as this correction.)
        // Full-res upgrades use a different key entirely, so they can never
        // be the pending entry this reads. Getting this wrong re-opens G-027 in the silent direction --
        // demoting the item the user is looking at -- which is why both
        // directions are asserted by test rather than argued here.
        //
        // This replaces the old plain `isPending` guard, whose sole purpose
        // (G-027: never demote a navigation entry from rank 0 to 2000+) is
        // preserved here by checking the pending priority's VALUE rather than
        // merely its presence. A priority >= kSidebarPayloadPriorityBase can
        // only ever have been set by the sidebar itself (navigation priorities
        // are always < kSidebarPayloadPriorityBase), so re-enqueueing such a
        // key is always safe -- and necessary, because DecodeLane.enqueue
        // REPLACES a pending entry's priority (decode_lane.dart:120-139): this
        // is what keeps an already-pending sidebar row's priority in step with
        // the CURRENT visible range as the user scrolls, instead of freezing
        // it at the range that first requested it.
        final key = (LaneTaskKind.payload, id);
        final pendingPriority = _decodeLane.pendingPriorityOf(key);
        if (pendingPriority == null || isSidebarPriority(pendingPriority)) {
          _enqueueSidebarPayload(
            item,
            priority: sidebarPriorityFor(
              index: index,
              safeStart: safeStart,
              safeEnd: safeEnd,
            ),
          );
        }
      }
    });
  }

  void reset() {
    _cache.clear();
    _waiters.clear();
    _notify = null;
    _enqueuedIds.clear();
    _loadingKeys.clear();
    _wantedIds = {};
    _priorityIds = [];
    _permanentMisses.clear();
    _lastPreloadStart = -1;
    _lastPreloadEnd = -1;
    _debounceTimer?.cancel();
    _batchGeneration++;
  }

  void dispose() {
    _debounceTimer?.cancel();
    _wantedIds = {};
    _priorityIds = [];
    _waiters.clear();
    _notify = null;
    _enqueuedIds.clear();
  }
}
