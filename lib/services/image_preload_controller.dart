import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/photo_item.dart';
import '../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'native_thumbnail_service.dart';

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

class ImagePreloadController {
  ImagePreloadController({
    required ImageBytesLoader imageLoader,
    DngFullDecoder? dngDecoder,
  }) : _imageLoader = imageLoader,
       _dngDecoder = dngDecoder;

  final ImageBytesLoader _imageLoader;

  // Null when no RAW decoder is available. Every use is guarded by the
  // mandatory no-regression fallback: no decoder (or a throwing one) means
  // the item is re-requested through NativeThumbnailService.getThumbnail,
  // which forces allowRawDecodeSignal: false and therefore reproduces the
  // pre-round-3b CIRAWFilter path byte-for-byte. Degraded, never blank.
  final DngFullDecoder? _dngDecoder;

  final Map<String, Uint8List> _imageCache = {};
  final Map<String, Uint8List> _thumbCache = {};
  final Set<String> _loadingKeys = {};
  // Callbacks from callers who selected an item while its preview load was
  // already in-flight (started by a previous preload pass). Flushed once the
  // in-flight load completes so the UI never strands on a permanent spinner.
  final Map<String, List<VoidCallback>> _pendingPreviewNotifies = {};

  // Tier-1 (window-resolution) decode precache bookkeeping.
  int? _tierOneWidth;
  int? _tierOneHeight;
  final Map<String, Object> _tierOneKeys = {};

  // Tier-2 (full size) decode precache bookkeeping. Own window (+/-1), own
  // key namespace (MemoryImage keys, distinct from tier-1's ResizeImageKey)
  // and own eviction so the two tiers coexist without either clobbering the
  // other's ImageCache entry for the same item id.
  //
  // _tierTwoKeys/_tierTwoBytes/_tierTwoReadyIds are id-keyed, but the
  // ImageCache entry they describe is keyed by BYTES OBJECT IDENTITY
  // (MemoryImage.== compares bytes by identity). When an item leaves the
  // bytes window (-3..+5) and later returns, _imageCache[id] holds a NEW
  // Uint8List, so a stale id-keyed "ready" flag would silently point at an
  // ImageCache entry for bytes that are no longer current -- readiness
  // must be re-derived at read time against the CURRENT bytes, not trusted
  // from bookkeeping alone (round-2 review BLOCKER 1).
  Timer? _tierTwoDebounceTimer;
  final Map<String, Object> _tierTwoKeys = {};
  final Map<String, Uint8List> _tierTwoBytes = {};
  final Set<String> _tierTwoReadyIds = {};

  // Raw-decode (round-3b) bookkeeping, for DNGs with no embedded full-size
  // JPEG. These items never get bytes at all -- `_imageCache` stays empty for
  // them -- so a single full-resolution `ui.Image` serves BOTH tiers.
  //
  // Memory is the binding constraint, not correctness: one decoded image is
  // 4080x3056 RGBA8 ~= 49.9MB. Decoding is therefore deliberately confined to
  // the tier-2 (+/-1) window, NOT the bytes window (-3..+5): the latter would
  // hold nine of them, ~450MB, against a 500MB ImageCache cap. Creation and
  // eviction both happen inside _decodeTierTwoWindow's single sweep, so the
  // resident set cannot exceed three even when navigation cancels the
  // debounce repeatedly (a cancelled pass creates nothing).
  final Map<String, int> _needsRawDecode = {}; // id -> EXIF orientation 1..8
  final Map<String, DecodedRgbaImageProvider> _decodedProviders = {};
  final Set<String> _rawDecodesInFlight = {};

  int _lastPreloadStart = -1;
  int _lastPreloadEnd = -1;
  Timer? _thumbnailDebounceTimer;

  Uint8List? imageBytesFor(String? id) => id == null ? null : _imageCache[id];

  Uint8List? thumbnailBytesFor(String id) => _thumbCache[id];

  /// The full-resolution, orientation-corrected provider for a DNG that had
  /// no embedded preview and was decoded natively, or null if [id] is not
  /// such an item (or its decode has not landed yet).
  ///
  /// The controller owns the provider object, so the display path gets the
  /// SAME object identity the controller evicts with -- the same rule as
  /// [tierOneProviderFor]/[fullSizeProviderFor], and the reason
  /// [DecodedRgbaImageProvider]'s equality is identity on its `ui.Image`.
  ///
  /// [isFullSizeReady] also reports true for such an item, via its own early
  /// return; the bytes path's three-way conjunction is untouched.
  DecodedRgbaImageProvider? decodedProviderFor(String? id) =>
      id == null ? null : _decodedProviders[id];

  /// Test/diagnostic access to the master handle whose lifetime this
  /// controller owns.
  @visibleForTesting
  ui.Image? decodedImageFor(String id) => _decodedProviders[id]?.image;

  /// Whether the full-size (tier-2) decode for [id] has COMPLETED and the
  /// resulting ImageCache entry is still resident **for the item's current
  /// bytes**. This is a conjunction of two independent facts, both
  /// required (round-2 review BLOCKER 1 and BLOCKER 3 each came from
  /// having only one of them):
  ///   1. `_tierTwoReadyIds.contains(id)` -- the decode listener's onImage
  ///      callback fired, i.e. the decode actually finished. Without this,
  ///      `ImageCache.containsKey` returns true for a PENDING entry too
  ///      (SDK image_cache.dart: `_pendingImages[key] != null ||
  ///      _cache[key] != null`), and `MemoryImage.obtainKey` resolves
  ///      synchronously right after `resolve()` inserts the pending entry
  ///      -- so a containsKey-only check flips true the instant a ~124ms
  ///      full-frame decode STARTS, not when it lands, which is worse than
  ///      not having tier-2 at all (BLOCKER 3).
  ///   2. `identical(decodedFor, currentBytes)` + `containsKey(key)` -- the
  ///      finished entry is still the one for the CURRENT bytes and is
  ///      still actually resident, not stale bookkeeping for bytes that
  ///      were since replaced/evicted (BLOCKER 1).
  /// Both checks are plain bookkeeping lookups, never a resolve. The
  /// display side uses this to switch providers seamlessly
  /// (gaplessPlayback) once it's true.
  ///
  /// The raw-decode path gets its OWN early return rather than being folded
  /// into the conjunction below. A decoded item has no bytes at all, so every
  /// term of that conjunction is vacuously false for it; merging the two
  /// would mean loosening terms that exist specifically to keep BLOCKER 1 and
  /// BLOCKER 3 dead. The bytes path below is unchanged.
  bool isFullSizeReady(String id) {
    // A decoded ui.Image IS the full-size image, and its presence in
    // _decodedProviders already means the decode COMPLETED (the entry is only
    // written after the future resolves) -- so this is not the
    // "pending decode looks ready" mistake of BLOCKER 3.
    if (_decodedProviders.containsKey(id)) return true;
    if (!_tierTwoReadyIds.contains(id)) return false;
    final key = _tierTwoKeys[id];
    if (key == null) return false;
    final decodedFor = _tierTwoBytes[id];
    final currentBytes = _imageCache[id];
    if (decodedFor == null || !identical(decodedFor, currentBytes)) {
      return false;
    }
    return PaintingBinding.instance.imageCache.containsKey(key);
  }

  void reset() {
    _imageCache.clear();
    _thumbCache.clear();
    _loadingKeys.clear();
    _pendingPreviewNotifies.clear();
    _tierOneKeys.clear();
    _tierTwoDebounceTimer?.cancel();
    for (final key in _tierTwoKeys.values) {
      PaintingBinding.instance.imageCache.evict(key);
    }
    _tierTwoKeys.clear();
    _tierTwoBytes.clear();
    _tierTwoReadyIds.clear();
    for (final id in _decodedProviders.keys.toList()) {
      _evictTierTwoEntry(id);
    }
    _needsRawDecode.clear();
    _lastPreloadStart = -1;
    _lastPreloadEnd = -1;
    _thumbnailDebounceTimer?.cancel();
  }

  /// Called by the view whenever the viewport's decode target size is known
  /// (window logical size x devicePixelRatio). Used only for the tier-1
  /// precache; the display path computes and passes the same size directly
  /// to [tierOneProviderFor] itself, so there is a single source of truth
  /// per frame and no risk of the two diverging.
  void updateTargetSize(int width, int height) {
    _tierOneWidth = width;
    _tierOneHeight = height;
  }

  void dispose() {
    _thumbnailDebounceTimer?.cancel();
    _tierTwoDebounceTimer?.cancel();
    // ~50MB per handle: leaking these on teardown is the whole reason this
    // path needs explicit ownership at all.
    for (final id in _decodedProviders.keys.toList()) {
      _evictTierTwoEntry(id);
    }
    // Decodes still RUNNING at teardown are structurally invisible to the
    // loop above -- they are not in _decodedProviders yet, and they will land
    // after this controller is gone, with nothing left to evict them.
    // Clearing the set makes the guard at the top of _runRawDecode fire, so
    // each late arrival disposes its own image instead of leaking it
    // permanently.
    _rawDecodesInFlight.clear();
  }

  Future<void> preloadImages({
    required List<PhotoItem> items,
    required String selectedItemId,
    required VoidCallback notifyLoaded,
  }) async {
    if (items.isEmpty) return;

    final currentIndex = items.indexWhere((item) => item.id == selectedItemId);
    if (currentIndex == -1) return;

    final startIdx = (currentIndex - 3).clamp(0, items.length - 1);
    final endIdx = (currentIndex + 5).clamp(0, items.length - 1);
    final neededIds = <String>{};

    for (var i = startIdx; i <= endIdx; i++) {
      neededIds.add(items[i].id);
    }

    // Any id dropped here will get a NEW Uint8List object if it's loaded
    // again later (see _loadPreview below) — the tier-2 entry decoded for
    // its OLD bytes is now orphaned (wrong cache key for the item going
    // forward) and must be evicted, not left to linger under a stale id
    // -> key mapping (round-2 review BLOCKER 1).
    final droppedIds = <String>[];
    _imageCache.removeWhere((id, _) {
      final drop = !neededIds.contains(id);
      if (drop) droppedIds.add(id);
      return drop;
    });
    for (final id in droppedIds) {
      _evictTierTwoEntry(id);
    }
    // Raw-decode items are never in _imageCache, so the removeWhere above
    // cannot see them; sweep their bookkeeping against the same window. The
    // decoded ui.Images themselves are evicted on the tighter +/-1 window
    // inside _decodeTierTwoWindow, but dispose here too so an item that
    // leaves the bytes window without another tier-2 pass ever running
    // cannot hold 50MB indefinitely.
    for (final id in _needsRawDecode.keys.toList()) {
      if (!neededIds.contains(id)) _needsRawDecode.remove(id);
    }
    for (final id in _decodedProviders.keys.toList()) {
      if (!neededIds.contains(id)) _evictTierTwoEntry(id);
    }
    _selectedIdForPerf = selectedItemId; // PERF-INSTRUMENTATION

    // PERF-INSTRUMENTATION
    final tPrio = PerfLog.us;
    final wasInFlight = _loadingKeys.contains(selectedItemId);
    final wasCached = _imageCache.containsKey(selectedItemId);
    PerfLog.log(
      'preload.priority.begin|$selectedItemId'
      '|cached=$wasCached|inFlight=$wasInFlight',
    );
    await _loadPreview(
      items.firstWhere((item) => item.id == selectedItemId),
      notifyLoaded: notifyLoaded,
    );
    // PERF-INSTRUMENTATION
    PerfLog.log(
      'preload.priority.end|$selectedItemId|dur=${PerfLog.us - tPrio}'
      '|nowCached=${_imageCache.containsKey(selectedItemId)}',
    );

    final pendingLoads = <Future<void>>[];
    for (var i = startIdx; i <= endIdx; i++) {
      pendingLoads.add(_loadPreview(items[i], notifyLoaded: null));
    }
    await Future.wait(pendingLoads);
    PerfLog.log('preload.window.end|$selectedItemId'); // PERF-INSTRUMENTATION

    _precacheTierOneWindow(items, currentIndex);
    _scheduleTierTwoDecode(items, currentIndex, notifyLoaded);
  }

  String? _selectedIdForPerf; // PERF-INSTRUMENTATION

  // Tier-2 debounce: every navigation event cancels and reschedules this
  // timer, so only the FINAL position after a burst of navigation ever
  // starts a full-size decode (AC3a/AC3b) — items only passed through
  // during continuous navigation are simply never queued, because their
  // scheduling attempt gets cancelled before it fires.
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

  // Tier-2 precache: decode current +/-1 at full size, once navigation has
  // paused. Both tiers coexist: this only evicts its own (+/-1) window's
  // entries, never touches _tierOneKeys or the underlying bytes cache.
  void _decodeTierTwoWindow(
    List<PhotoItem> items,
    int currentIndex,
    VoidCallback notifyLoaded,
  ) {
    final tierStart = (currentIndex - 1).clamp(0, items.length - 1);
    final tierEnd = (currentIndex + 1).clamp(0, items.length - 1);
    final neededIds = <String>{};

    for (var i = tierStart; i <= tierEnd; i++) {
      final item = items[i];
      // Raw-decode items have no bytes by construction; their single
      // full-resolution ui.Image is produced here and serves both tiers.
      final orientation = _needsRawDecode[item.id];
      if (orientation != null) {
        neededIds.add(item.id);
        _startRawDecode(item, orientation, notifyLoaded);
        continue;
      }
      final bytes = _imageCache[item.id];
      if (bytes == null) continue; // not loaded yet; retried on next pass
      neededIds.add(item.id);
      // Only skip if the id's ready flag was set for THESE bytes -- if the
      // item's bytes were replaced (e.g. it briefly left the -3..+5 window
      // and got reloaded) since the last decode, this is stale and must be
      // redone against the current object, not the one the old key points
      // at (round-2 review BLOCKER 1).
      final alreadyDecoded =
          _tierTwoReadyIds.contains(item.id) &&
          identical(_tierTwoBytes[item.id], bytes);
      if (alreadyDecoded) continue;
      _decodeFullSizeIntoImageCache(item.id, bytes, notifyLoaded);
    }

    // Union of all THREE populations, because tier-2 state for an item can
    // live in any of them and in only one at a time:
    //   _tierTwoKeys        byte-backed entries
    //   _decodedProviders   raw decodes that have LANDED
    //   _rawDecodesInFlight raw decodes still RUNNING
    // The third was missing and caused a real leak: an id whose decode was
    // still running when its item left the window was in no swept collection,
    // so _evictTierTwoEntry never cleared its in-flight flag, so the guard at
    // the top of _runRawDecode did not fire and the finished ~50MB image was
    // written into _decodedProviders for an item nothing tracks any more.
    //
    // A NOTE ON `_needsRawDecode` -- DO NOT read this as "clearing it on
    // success is safe". It is not safe; it is currently non-fatal, and only
    // by a timing coincidence. Both halves of that were established by
    // mutation, not by reading the code (tmp/verify/r3b/leak_fix.txt):
    //
    // 1. COST, TODAY, REAL: clearing `_needsRawDecode[id]` once a decode
    //    succeeds makes `_loadPreview` re-ask the native side for that item on
    //    EVERY subsequent navigation, for an answer that cannot change -- the
    //    exact regression its early return exists to prevent. Guarded by the
    //    test "a raw item is requested from the native loader exactly ONCE".
    //
    // 2. IT DOES NOT DISPOSE ANYTHING TODAY -- BUT ONLY BECAUSE OF ORDERING.
    //    An in-window raw item reaches `neededIds` via `_needsRawDecode`, so
    //    it looks as though clearing it would make this sweep evict the image
    //    that just landed. It does not, because `_requestPreviewBytes`
    //    repopulates the entry during `preloadImages`, and that pass finishes
    //    BEFORE this sweep runs -- the sweep is on the `tierTwoNavigationDebounce`
    //    timer scheduled at the end of that same pass. Repopulation wins a
    //    race. That is a coincidence of timing, NOT a structural guarantee.
    //
    // 3. THEREFORE: anyone changing `tierTwoNavigationDebounce` -- shortening
    //    it below the preload round-trip, removing it, or making this sweep
    //    synchronous -- MUST re-check this ordering. Flip it and the eviction
    //    described in (2) starts happening for real: the freshly decoded image
    //    is disposed out from under the display. Round 3c owns that debounce,
    //    and nothing about a perf change to it advertises that it touches
    //    image lifetime. This paragraph is the only warning there is.
    final staleIds = <String>{
      ..._tierTwoKeys.keys,
      ..._decodedProviders.keys,
      ..._rawDecodesInFlight,
    }.where((id) => !neededIds.contains(id)).toList();
    for (final id in staleIds) {
      _evictTierTwoEntry(id);
    }
  }

  // Starts (at most one) raw decode for [item]. Idempotent: a decode already
  // resident or in flight is left alone, so re-entering the tier-2 window
  // never decodes the same photo twice.
  void _startRawDecode(
    PhotoItem item,
    int orientation,
    VoidCallback notifyLoaded,
  ) {
    final id = item.id;
    if (_decodedProviders.containsKey(id) || _rawDecodesInFlight.contains(id)) {
      return;
    }
    final decoder = _dngDecoder;
    final file = item.bestFileToLoad;
    if (decoder == null || file == null) return;
    _rawDecodesInFlight.add(id);
    unawaited(
      _runRawDecode(item, file.path, orientation, decoder, notifyLoaded),
    );
  }

  Future<void> _runRawDecode(
    PhotoItem item,
    String path,
    int orientation,
    DngFullDecoder decoder,
    VoidCallback notifyLoaded,
  ) async {
    final id = item.id;
    final tDecode = PerfLog.us; // PERF-INSTRUMENTATION
    try {
      final decoded = await decoder(path);
      final image = await decodedRgbaToImage(
        decoded,
        exifOrientation: orientation,
      );
      // The item may have left the window while the ~50MB decode was in
      // flight; _evictTierTwoEntry clears the in-flight marker precisely so
      // this late arrival disposes itself instead of resurrecting an entry
      // nothing will ever evict.
      if (!_rawDecodesInFlight.contains(id)) {
        image.dispose();
        return;
      }
      _decodedProviders[id] = DecodedRgbaImageProvider(image);
      // PERF-INSTRUMENTATION
      PerfLog.log(
        'rawDecode.ready|$id|${image.width}x${image.height}'
        '|orient=$orientation|dur=${PerfLog.us - tDecode}',
      );
      notifyLoaded();
    } catch (error) {
      // PERF-INSTRUMENTATION
      PerfLog.log('rawDecode.fail|$id|dur=${PerfLog.us - tDecode}|$error');
      // Mandatory no-regression fallback (design §2): a throwing decoder must
      // degrade to the pre-round-3b CIRAWFilter path, never to a blank
      // screen. _needsRawDecode is cleared first so the next preload pass
      // treats this as an ordinary bytes item.
      _needsRawDecode.remove(id);
      await _fallbackToLegacyBytes(id, path, notifyLoaded);
    } finally {
      _rawDecodesInFlight.remove(id);
    }
  }

  // Re-requests [path] with allowRawDecodeSignal forced to false (that is
  // what NativeThumbnailService.getThumbnail always sends), which reproduces
  // the pre-round-3b native behaviour byte-for-byte: CIRAWFilter, 2800px cap,
  // slow -- but a picture. Used when there is no decoder and when one throws.
  Future<void> _fallbackToLegacyBytes(
    String id,
    String path,
    VoidCallback? notifyLoaded,
  ) async {
    final bytes = await NativeThumbnailService.getThumbnail(
      path,
      purpose: ImageRequestPurpose.preview,
    );
    if (bytes == null) return;
    _imageCache[id] = bytes;
    notifyLoaded?.call();
  }

  void _decodeFullSizeIntoImageCache(
    String id,
    Uint8List bytes,
    VoidCallback notifyLoaded,
  ) {
    final provider = fullSizeProviderFor(bytes);
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
      _tierTwoBytes[id] = bytes;
    });
  }

  // Removes id's tier-2 bookkeeping and evicts its ImageCache entry (if
  // any). Never touches _tierOneKeys or _imageCache -- tier-1 and the bytes
  // cache have their own, separate lifecycles.
  //
  // Tier-2 for an item is EITHER a byte-backed MemoryImage entry OR a
  // raw-decoded ui.Image, never both, so both live here: one eviction path
  // means a new call site cannot free one kind and leak the other.
  void _evictTierTwoEntry(String id) {
    final key = _tierTwoKeys.remove(id);
    _tierTwoBytes.remove(id);
    _tierTwoReadyIds.remove(id);
    if (key != null) {
      PaintingBinding.instance.imageCache.evict(key);
    }

    // Clearing the in-flight marker makes a decode that lands AFTER this
    // eviction dispose its own ~50MB result instead of resurrecting the entry
    // (see the guard at the top of _runRawDecode).
    //
    // This only helps if this method is actually CALLED for an in-flight id.
    // It originally was not: every caller iterated _imageCache's dropped ids
    // (raw items are never in _imageCache), _decodedProviders (empty while
    // the decode is still running) or _tierTwoKeys (byte-backed only) -- so
    // the in-flight case fell through every sweep and leaked. The stale union
    // in _decodeTierTwoWindow now includes _rawDecodesInFlight, and dispose()
    // clears the set outright, which are the two call paths that make this
    // line reachable for an in-flight id.
    _rawDecodesInFlight.remove(id);
    final provider = _decodedProviders.remove(id);
    if (provider == null) return;
    // Evict BEFORE disposing the master: the cache holds a clone, and
    // dropping that handle first keeps the pixels alive for anything still
    // painting this frame.
    PaintingBinding.instance.imageCache.evict(provider);
    provider.image.dispose();
  }

  // Tier-1 precache: decode current +/-2 at window resolution ahead of
  // display, using the SAME provider factory the view uses. Requires
  // [updateTargetSize] to have been called at least once (from a previous
  // layout pass); no-ops otherwise, degrading to on-demand full decode at
  // display time (functionally correct, just slower for that frame).
  void _precacheTierOneWindow(List<PhotoItem> items, int currentIndex) {
    final width = _tierOneWidth;
    final height = _tierOneHeight;
    if (width == null || height == null) return;

    final tierStart = (currentIndex - 2).clamp(0, items.length - 1);
    final tierEnd = (currentIndex + 2).clamp(0, items.length - 1);
    final neededIds = <String>{};

    for (var i = tierStart; i <= tierEnd; i++) {
      final item = items[i];
      final bytes = _imageCache[item.id];
      if (bytes == null) continue; // not loaded yet; retried on next pass
      neededIds.add(item.id);
      _decodeIntoImageCache(
        item.id,
        tierOneProviderFor(bytes, width: width, height: height),
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

  // Returns preview bytes, or null when there are none to cache -- which now
  // has two causes: a genuine failure (as before), or "this DNG needs a real
  // RAW decode", in which case the orientation is recorded and tier-2 picks
  // it up. Both look identical to the caller on purpose: neither puts bytes
  // in _imageCache.
  Future<Uint8List?> _requestPreviewBytes(String id, String path) async {
    final result = await _imageLoader(
      path,
      purpose: ImageRequestPurpose.preview,
    );
    switch (result) {
      case NativeImageBytes(:final bytes):
        return bytes;
      case NativeImageNeedsRawDecode(:final exifOrientation):
        if (_dngDecoder == null) {
          // Mandatory no-regression fallback (design §2), the no-decoder
          // half: ask again with allowRawDecodeSignal false and use the old
          // CIRAWFilter bytes rather than showing nothing.
          return NativeThumbnailService.getThumbnail(
            path,
            purpose: ImageRequestPurpose.preview,
          );
        }
        _needsRawDecode[id] = exifOrientation;
        return null;
      case NativeImageFailure():
        return null;
    }
  }

  Future<void> _loadPreview(
    PhotoItem item, {
    required VoidCallback? notifyLoaded,
  }) async {
    final id = item.id;
    if (_imageCache.containsKey(id)) {
      // PERF-INSTRUMENTATION
      PerfLog.log(
        'loadPreview.skip|$id|cached=true|inFlight=false'
        '|isSelected=${id == _selectedIdForPerf}',
      );
      return;
    }

    // Already known to need a real RAW decode: tier-2 owns it from here, and
    // re-asking the native side on every preload pass would be a channel
    // round-trip per navigation for an answer that cannot change.
    if (_needsRawDecode.containsKey(id)) return;

    if (_loadingKeys.contains(id)) {
      // Someone else's load for this item is already in flight (e.g. it was
      // queued by a previous preload pass, or the caller selected an item
      // that is mid-window-load). Register to be notified when it lands
      // instead of dropping the callback, which used to strand the spinner
      // forever.
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

    _loadingKeys.add(id);
    final tCh = PerfLog.us; // PERF-INSTRUMENTATION
    try {
      final bytes = await _requestPreviewBytes(id, file.path);
      // PERF-INSTRUMENTATION
      PerfLog.log(
        'channel.preview|$id|bytes=${bytes?.length ?? -1}'
        '|roundtrip=${PerfLog.us - tCh}|notify=${notifyLoaded != null}'
        '|isSelected=${id == _selectedIdForPerf}',
      );
      if (bytes != null) {
        _imageCache[id] = bytes;
        notifyLoaded?.call();
        final pending = _pendingPreviewNotifies.remove(id);
        if (pending != null) {
          for (final cb in pending) {
            cb();
          }
        }
      } else {
        _pendingPreviewNotifies.remove(id);
      }
    } catch (_) {
      // The loader threw (e.g. a PlatformException the native side didn't
      // convert to null, or a MissingPluginException on an unimplemented
      // platform handler). Flush anyone who selected this item while the
      // load was in flight so they don't strand on a permanent spinner and
      // the pending-notify map doesn't grow unbounded -- same rationale as
      // the success path (R3), just reached via the exception path
      // (round-2 review S1). Preserve existing error propagation.
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

    _thumbnailDebounceTimer?.cancel();
    _thumbnailDebounceTimer = Timer(
      const Duration(milliseconds: 100),
      () async {
        final neededThumbIds = <String>{};
        for (var i = safeStart; i <= safeEnd; i++) {
          neededThumbIds.add(items[i].id);
        }

        _thumbCache.removeWhere((key, _) => !neededThumbIds.contains(key));

        for (final id in neededThumbIds) {
          final loadingKey = 'thumb_$id';
          if (_thumbCache.containsKey(id) ||
              _loadingKeys.contains(loadingKey)) {
            continue;
          }

          final item = items.firstWhere((candidate) => candidate.id == id);
          final file = item.bestFileToLoad;
          if (file == null) continue;

          _loadingKeys.add(loadingKey);
          // Native only ever emits NO_EMBEDDED_PREVIEW for purpose ==
          // preview, so for thumbnails anything that is not bytes is simply
          // "no thumbnail", exactly as null was before.
          final result = await _imageLoader(
            file.path,
            purpose: ImageRequestPurpose.sidebarThumbnail,
          );
          if (result is NativeImageBytes) {
            _thumbCache[id] = result.bytes;
            notifyLoaded();
          }
          _loadingKeys.remove(loadingKey);
        }
      },
    );
  }
}

typedef VoidCallback = void Function();
