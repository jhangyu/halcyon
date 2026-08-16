import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import '../models/photo_item.dart';
import 'native_thumbnail_service.dart';

typedef ImageBytesLoader =
    Future<Uint8List?> Function(
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
  ImagePreloadController({required ImageBytesLoader imageLoader})
    : _imageLoader = imageLoader;

  final ImageBytesLoader _imageLoader;
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

  int _lastPreloadStart = -1;
  int _lastPreloadEnd = -1;
  Timer? _thumbnailDebounceTimer;

  Uint8List? imageBytesFor(String? id) => id == null ? null : _imageCache[id];

  Uint8List? thumbnailBytesFor(String id) => _thumbCache[id];

  /// Whether the full-size (tier-2) decode for [id] has landed in
  /// ImageCache **for the item's current bytes**. Re-derived at read time
  /// against `_imageCache[id]` and `imageCache.containsKey` (both are plain
  /// bookkeeping lookups, never a resolve) rather than trusted from a
  /// standing flag: `_tierTwoReadyIds` alone cannot tell a currently-valid
  /// entry from one decoded for bytes that have since been evicted/replaced
  /// by [preloadImages]'s bytes-window sweep, or from an entry ImageCache
  /// itself dropped under LRU pressure. The display side uses this to
  /// switch providers seamlessly (gaplessPlayback) once it's true.
  bool isFullSizeReady(String id) {
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

    await _loadPreview(
      items.firstWhere((item) => item.id == selectedItemId),
      notifyLoaded: notifyLoaded,
    );

    final pendingLoads = <Future<void>>[];
    for (var i = startIdx; i <= endIdx; i++) {
      pendingLoads.add(_loadPreview(items[i], notifyLoaded: null));
    }
    await Future.wait(pendingLoads);

    _precacheTierOneWindow(items, currentIndex);
    _scheduleTierTwoDecode(items, currentIndex, notifyLoaded);
  }

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

    final staleIds = _tierTwoKeys.keys
        .where((id) => !neededIds.contains(id))
        .toList();
    for (final id in staleIds) {
      _evictTierTwoEntry(id);
    }
  }

  void _decodeFullSizeIntoImageCache(
    String id,
    Uint8List bytes,
    VoidCallback notifyLoaded,
  ) {
    final provider = fullSizeProviderFor(bytes);
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) {
        stream.removeListener(listener);
        _tierTwoReadyIds.add(id);
        notifyLoaded();
      },
      onError: (error, stackTrace) => stream.removeListener(listener),
    );
    stream.addListener(listener);
    provider.obtainKey(const ImageConfiguration()).then((key) {
      _tierTwoKeys[id] = key;
      _tierTwoBytes[id] = bytes;
    });
  }

  // Removes id's tier-2 bookkeeping and evicts its ImageCache entry (if
  // any). Never touches _tierOneKeys or _imageCache -- tier-1 and the bytes
  // cache have their own, separate lifecycles.
  void _evictTierTwoEntry(String id) {
    final key = _tierTwoKeys.remove(id);
    _tierTwoBytes.remove(id);
    _tierTwoReadyIds.remove(id);
    if (key != null) {
      PaintingBinding.instance.imageCache.evict(key);
    }
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

  Future<void> _loadPreview(
    PhotoItem item, {
    required VoidCallback? notifyLoaded,
  }) async {
    final id = item.id;
    if (_imageCache.containsKey(id)) {
      return;
    }

    if (_loadingKeys.contains(id)) {
      // Someone else's load for this item is already in flight (e.g. it was
      // queued by a previous preload pass, or the caller selected an item
      // that is mid-window-load). Register to be notified when it lands
      // instead of dropping the callback, which used to strand the spinner
      // forever.
      if (notifyLoaded != null) {
        _pendingPreviewNotifies.putIfAbsent(id, () => []).add(notifyLoaded);
      }
      return;
    }

    final file = item.bestFileToLoad;
    if (file == null) return;

    _loadingKeys.add(id);
    try {
      final bytes = await _imageLoader(
        file.path,
        purpose: ImageRequestPurpose.preview,
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
          final bytes = await _imageLoader(
            file.path,
            purpose: ImageRequestPurpose.sidebarThumbnail,
          );
          if (bytes != null) {
            _thumbCache[id] = bytes;
            notifyLoaded();
          }
          _loadingKeys.remove(loadingKey);
        }
      },
    );
  }
}

typedef VoidCallback = void Function();
