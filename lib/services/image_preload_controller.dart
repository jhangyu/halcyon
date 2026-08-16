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

  int _lastPreloadStart = -1;
  int _lastPreloadEnd = -1;
  Timer? _thumbnailDebounceTimer;

  Uint8List? imageBytesFor(String? id) => id == null ? null : _imageCache[id];

  Uint8List? thumbnailBytesFor(String id) => _thumbCache[id];

  void reset() {
    _imageCache.clear();
    _thumbCache.clear();
    _loadingKeys.clear();
    _pendingPreviewNotifies.clear();
    _tierOneKeys.clear();
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

    _imageCache.removeWhere((key, _) => !neededIds.contains(key));

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
