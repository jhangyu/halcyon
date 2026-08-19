import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/photo_item.dart';
import '../models/supported_photo_formats.dart';
import '../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import '../services/decoded_rgba_image_provider.dart';
import '../services/dng_decode_contract.dart';
import '../services/image_preload_controller.dart';
import '../services/native_thumbnail_service.dart';
import '../services/photo_file_actions.dart';
import '../services/photo_library_scanner.dart';
import '../services/photo_status_store.dart';

typedef ThumbnailLoader =
    Future<NativeImageResult> Function(
      String path, {
      required ImageRequestPurpose purpose,
    });

/// Outcome of a batch delete, returned to the view layer so feedback lives
/// in the widgets rather than the provider. Failures are never swallowed.
class BatchDeleteResult {
  const BatchDeleteResult({
    required this.recycled,
    required this.movedCount,
    required this.failures,
    this.trashDirPath,
  });

  final bool recycled;
  final int movedCount;
  final List<String> failures;
  final String? trashDirPath;
}

/// A transient line shown at the bottom of the window (see `StatusLine`).
///
/// `*…*` in [text] marks the amber emphasis span. [revealPath], when set,
/// adds a "顯示" button that opens that path in Finder.
class StatusMessage {
  const StatusMessage(this.text, {this.revealPath});

  final String text;
  final String? revealPath;
}

class AppState extends ChangeNotifier {
  AppState({
    PhotoLibraryScanner? scanner,
    PhotoStatusStore? statusStore,
    PhotoFileActions? fileActions,
    ImagePreloadController? preloadController,
    ThumbnailLoader? thumbnailLoader,
    DngFullDecoder? dngDecoder,
  }) : _scanner = scanner ?? PhotoLibraryScanner(),
       _statusStore = statusStore ?? PhotoStatusStore(),
       _fileActions = fileActions ?? PhotoFileActions(),
       _preloadController =
           preloadController ??
           ImagePreloadController(
             imageLoader:
                 thumbnailLoader ??
                 ((path, {required purpose}) =>
                     NativeThumbnailService.requestImage(
                       path,
                       purpose: purpose,
                     )),
             // Null until the app's composition root injects the pkg squad's
             // adapter. While null, a DNG with no embedded preview falls back
             // to the legacy CIRAWFilter bytes rather than showing nothing.
             dngDecoder: dngDecoder,
           ) {
    _initPrefs();
  }

  final PhotoLibraryScanner _scanner;
  final PhotoStatusStore _statusStore;
  final PhotoFileActions _fileActions;
  final ImagePreloadController _preloadController;

  Directory? _currentDir;
  List<PhotoItem> _items = [];
  String? _selectedItemID;
  Timer? _viewDebounceTimer;

  // Settings
  bool _autoAdvance = false;
  bool _overwriteExisting = true;
  SharedPreferences? _prefs;

  // Per-folder, deliberately NOT persisted: every loadFolder re-detects, so
  // a new card always starts from the safe default.
  bool _recycleMode = false;

  // The status line's current message. [_statusSeq] bumps on every show so the
  // view can restart its timer even when the same text repeats.
  StatusMessage? _status;
  int _statusSeq = 0;

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _autoAdvance = _prefs?.getBool('autoAdvance') ?? false;
    _overwriteExisting = _prefs?.getBool('overwriteExisting') ?? true;
    notifyListeners();
  }

  // Zoom retention
  final TransformationController transformCtrl = TransformationController();
  Offset? pointerPosition;
  Offset lastKnownCenter = const Offset(400, 300);

  // Animation requests
  Matrix4? targetMatrix;
  bool shouldAnimateZoom = false;

  List<PhotoItem> get items => _items;
  String? get selectedItemID => _selectedItemID;
  Directory? get currentDir => _currentDir;
  bool get autoAdvance => _autoAdvance;
  bool get overwriteExisting => _overwriteExisting;

  bool get recycleMode => _recycleMode;

  StatusMessage? get status => _status;
  int get statusSeq => _statusSeq;

  void showStatus(StatusMessage message) {
    _status = message;
    _statusSeq++;
    notifyListeners();
  }

  void toggleRecycleMode() {
    _recycleMode = !_recycleMode;
    notifyListeners();
  }

  PhotoItem? get currentItem {
    if (_selectedItemID == null) return null;
    return _items.firstWhere(
      (item) => item.id == _selectedItemID,
      orElse: () => _items.first,
    );
  }

  Uint8List? get currentImageBytes =>
      _preloadController.imageBytesFor(_selectedItemID);

  /// Non-null when the current item is a DNG with no embedded preview whose
  /// native RAW decode has landed. Such items have NO preview bytes at all
  /// ([currentImageBytes] stays null for them), so this single
  /// full-resolution provider serves what would otherwise be tier-1 and
  /// tier-2, and the view must check it before it decides to show a spinner.
  DecodedRgbaImageProvider? get currentDecodedProvider =>
      _preloadController.decodedProviderFor(_selectedItemID);

  Uint8List? getThumbnailBytes(String id) =>
      _preloadController.thumbnailBytesFor(id);

  /// True once the current item's full-size (tier-2) decode has landed in
  /// ImageCache; the view uses this to switch providers seamlessly instead
  /// of resolving the full-size provider itself to find out.
  bool get currentItemHasFullSize {
    final id = _selectedItemID;
    return id != null && _preloadController.isFullSizeReady(id);
  }

  // Forwards the current detail viewport's decode target size (logical size
  // x devicePixelRatio, computed by the view) to the preload controller so
  // its tier-1 precache decodes neighbors at the same resolution the view
  // will request. Silent update, no notifyListeners (mirrors
  // lastKnownCenter): this doesn't change what's displayed this frame.
  void setViewportSize(int width, int height) {
    _preloadController.updateTargetSize(width, height);
  }

  Future<void> openFolder() async {
    final String? directoryPath = await getDirectoryPath();
    if (directoryPath != null) {
      await loadFolder(Directory(directoryPath));
    }
  }

  /// Opens the folder containing [path] and selects that photo. Entry point
  /// for OS-handed files (see [OpenWithChannel]); unsupported extensions are
  /// ignored rather than clearing the folder the user is already viewing.
  Future<void> openPhotoAtPath(String path) async {
    if (!SupportedPhotoFormats.isSupportedPath(path)) return;
    final file = File(path);
    await loadFolder(
      file.parent,
      targetSelectionId: SupportedPhotoFormats.photoIdFor(file),
    );
  }

  Future<void> loadFolder(
    Directory dir, {
    String? targetSelectionId,
    int? targetFallbackIndex,
  }) async {
    _currentDir = dir;
    _items.clear();
    _preloadController.reset();
    _selectedItemID = null;
    notifyListeners();

    try {
      _items = await _scanner.scan(dir);
      // A folder holding same-name sibling groups is a camera card being
      // culled: default to recycling so a mis-click can't take the RAW with it.
      _recycleMode = _items.any((item) => item.files.length > 1);
      if (!await _statusStore.isWritable(dir)) {
        showStatus(
          const StatusMessage('此卷宗為*唯讀*，標記不會被儲存（檢查記憶卡的防寫鎖）'),
        );
      }
      String? lastViewedId;

      try {
        final snapshot = await _statusStore.applySavedStatuses(dir, _items);
        lastViewedId = snapshot.lastViewedId;
      } catch (e) {
        debugPrint("Error reading status JSON: $e");
      }

      if (_items.isNotEmpty) {
        if (targetSelectionId != null &&
            _items.any((item) => item.id == targetSelectionId)) {
          selectItem(targetSelectionId);
        } else if (targetFallbackIndex != null &&
            targetFallbackIndex < _items.length) {
          selectItem(_items[targetFallbackIndex].id);
        } else if (lastViewedId != null &&
            _items.any((item) => item.id == lastViewedId)) {
          selectItem(lastViewedId);
        } else if (targetFallbackIndex != null && _items.isNotEmpty) {
          selectItem(
            _items.last.id,
          ); // Fallback to last item if index is out of bounds
        } else {
          selectItem(_items.first.id);
        }
        preloadThumbnails(0, 20); // Initial preloading window for the sidebar
      } else {
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error loading directory: $e");
    }
  }

  void selectItem(String id) {
    if (_selectedItemID != id) {
      final tEnter = PerfLog.us; // PERF-INSTRUMENTATION
      PerfLog.log('selectItem.enter|$id'); // PERF-INSTRUMENTATION
      _selectedItemID = id;
      // PERF-INSTRUMENTATION
      final cached = _preloadController.imageBytesFor(id);
      PerfLog.log(
        'cache.${cached != null ? "hit" : "miss"}|$id|${cached?.length ?? 0}',
      );
      _preloadImages();

      _viewDebounceTimer?.cancel();
      _viewDebounceTimer = Timer(const Duration(seconds: 5), _saveLastViewedId);

      // PERF-INSTRUMENTATION
      PerfLog.log('selectItem.notify|$id|sinceEnter=${PerfLog.us - tEnter}');
      notifyListeners();
    }
  }

  void nextPhoto() {
    if (_items.isEmpty || _selectedItemID == null) return;
    final idx = _items.indexWhere((item) => item.id == _selectedItemID);
    if (idx != -1 && idx < _items.length - 1) {
      selectItem(_items[idx + 1].id);
    }
  }

  void previousPhoto() {
    if (_items.isEmpty || _selectedItemID == null) return;
    final idx = _items.indexWhere((item) => item.id == _selectedItemID);
    if (idx > 0) {
      selectItem(_items[idx - 1].id);
    }
  }

  // Zoom logic
  void stepZoomIn() {
    _zoomBy(1.25);
  }

  void stepZoomOut() {
    _zoomBy(1 / 1.25);
  }

  void _zoomBy(double scaleFactor) {
    double currentScale = transformCtrl.value.getMaxScaleOnAxis();
    double targetScale = currentScale * scaleFactor;

    // If we're hitting or going below 1.0x, snap perfectly back to the center avoiding boundary drifting
    if (targetScale <= 1.05) {
      targetMatrix = Matrix4.identity();
      shouldAnimateZoom = true;
      notifyListeners();
      return;
    }

    if (targetScale > 5.0) {
      scaleFactor = 5.0 / currentScale;
    }

    if (scaleFactor == 1.0) return;

    final focalPoint = pointerPosition ?? lastKnownCenter;

    // Translate to focal point, scale, and translate back
    final Matrix4 m = Matrix4.identity()
      ..translateByDouble(focalPoint.dx, focalPoint.dy, 0, 1)
      ..scaleByDouble(scaleFactor, scaleFactor, 1, 1)
      ..translateByDouble(-focalPoint.dx, -focalPoint.dy, 0, 1);

    targetMatrix = m.multiplied(transformCtrl.value);
    shouldAnimateZoom = true;
    notifyListeners();
  }

  void markCurrent(PhotoStatus status) {
    final item = currentItem;
    if (item != null) {
      if (item.status == status) {
        item.status = PhotoStatus.unmarked; // Toggle off if already set
      } else {
        item.status = status;
        if (_autoAdvance) {
          nextPhoto();
        }
      }
      _saveStatusCache();
      notifyListeners();
    }
  }

  Future<void> _saveStatusCache() async {
    final dir = _currentDir;
    if (dir == null) return;

    try {
      await _statusStore.saveStatuses(dir, _items);
    } catch (e) {
      debugPrint("Error saving status JSON: $e");
    }
  }

  Future<void> _saveLastViewedId() async {
    final dir = _currentDir;
    if (dir == null || _selectedItemID == null) return;

    try {
      await _statusStore.saveLastViewedId(dir, _selectedItemID!);
    } catch (e) {
      debugPrint("Error silently saving last viewed ID: $e");
    }
  }

  void setAutoAdvance(bool value) {
    _autoAdvance = value;
    _prefs?.setBool('autoAdvance', value);
    notifyListeners();
  }

  void setOverwriteExisting(bool value) {
    _overwriteExisting = value;
    _prefs?.setBool('overwriteExisting', value);
    notifyListeners();
  }

  // Preload sliding window: Previous 3, Current, Next 5
  Future<void> _preloadImages() async {
    final selectedId = _selectedItemID;
    if (selectedId == null) return;

    await _preloadController.preloadImages(
      items: _items,
      selectedItemId: selectedId,
      notifyLoaded: notifyListeners,
    );
  }

  // Preload a specific range of thumbnails (targetSize 200) for the sidebar +/- 20 range
  Future<void> preloadThumbnails(int startIdx, int endIdx) async {
    await _preloadController.preloadThumbnails(
      items: _items,
      startIdx: startIdx,
      endIdx: endIdx,
      notifyLoaded: notifyListeners,
    );
  }

  // Actions
  Future<void> processStarred(String destinationStr, bool move) async {
    final destDir = Directory(destinationStr);

    final currentId = _selectedItemID;
    final currentIndex = _items.indexWhere((i) => i.id == currentId);

    try {
      await _fileActions.processStarred(
        _items,
        destDir,
        move: move,
        overwriteExisting: _overwriteExisting,
      );
    } catch (e) {
      debugPrint("Error processing starred items: $e");
    }

    if (_currentDir != null) {
      await loadFolder(
        _currentDir!,
        targetSelectionId: currentId,
        targetFallbackIndex: currentIndex,
      );
    }
  }

  Future<BatchDeleteResult> deleteTrashed() async {
    final currentId = _selectedItemID;
    final currentIndex = _items.indexWhere((i) => i.id == currentId);
    final dir = _currentDir;
    final recycled = _recycleMode;

    var movedCount = 0;
    final failures = <String>[];
    String? trashDirPath;

    try {
      if (recycled && dir != null) {
        trashDirPath = p.join(dir.path, '.trash');
        final outcome = await _fileActions.recycleTrashed(_items, dir);
        movedCount = outcome.movedCount;
        failures.addAll(outcome.failures);
      } else {
        await _fileActions.deleteTrashed(_items);
      }
    } catch (e) {
      // Previously this only debugPrint()ed, so a card where the system trash
      // is unavailable looked like a broken app. Report it instead.
      failures.add('$e');
    }

    if (dir != null) {
      await loadFolder(
        dir,
        targetSelectionId: currentId,
        targetFallbackIndex: currentIndex,
      );
    }

    return BatchDeleteResult(
      recycled: recycled,
      movedCount: movedCount,
      failures: failures,
      trashDirPath: trashDirPath,
    );
  }

  @override
  void dispose() {
    _viewDebounceTimer?.cancel();
    _preloadController.dispose();
    transformCtrl.dispose();
    super.dispose();
  }
}
