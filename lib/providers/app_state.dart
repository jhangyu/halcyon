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
import '../services/dart_image_loader.dart';
import '../services/dng_decode_contract.dart';
import '../services/exif_metadata_service.dart';
import '../services/image_preload_controller.dart';
import '../services/native_thumbnail_service.dart';
import '../services/photo_file_actions.dart';
import '../services/photo_library_scanner.dart';
import '../services/photo_status_store.dart';
import '../services/raw_pixels_image.dart';
import '../services/rename_rule.dart';
import '../services/rename_service.dart';
import '../services/thumbnail_export_service.dart';

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
  const StatusMessage(
    this.text, {
    this.revealPath,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final String? revealPath;

  /// Optional trailing button (e.g. "還原" after a rename batch).
  final String? actionLabel;
  final VoidCallback? onAction;
}

class AppState extends ChangeNotifier {
  AppState({
    PhotoLibraryScanner? scanner,
    PhotoStatusStore? statusStore,
    PhotoFileActions? fileActions,
    ImagePreloadController? preloadController,
    ThumbnailLoader? thumbnailLoader,
    DngFullDecoder? dngDecoder,
    ThumbnailExportService? exportService,
    ExifBatchReader? exifReader,
  }) : _scanner = scanner ?? PhotoLibraryScanner(),
       _exifReader = exifReader ?? ExifMetadataService.readBatch,
       _statusStore = statusStore ?? PhotoStatusStore(),
       _fileActions = fileActions ?? PhotoFileActions(),
       _exportService = exportService ?? ThumbnailExportService(),
       _preloadController =
           preloadController ??
           ImagePreloadController(
             imageLoader: thumbnailLoader ?? dartImageLoad,
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
  final ThumbnailExportService _exportService;
  final ExifBatchReader _exifReader;

  bool _isRenaming = false;
  bool _renameCancelled = false;

  /// old id -> new id for the most recent batch, used to unwind marks on undo.
  Map<String, String> _lastRenameIdMap = const {};

  bool get isRenaming => _isRenaming;

  void cancelRename() {
    _renameCancelled = true;
  }

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

  // Zoom/animation state deliberately does NOT live here: it is pure view
  // state, owned by ZoomController (lib/views/zoom_controller.dart), which
  // MainScreen creates. See memory.md G-010 / Task 19.

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

  /// Non-null when the current item is one whose source produced PIXELS rather
  /// than an encoded bitstream -- a file with no usable embedded JPEG, decoded
  /// natively and reduced to window resolution. Such items have no preview
  /// bytes at all ([currentImageBytes] stays null for them), so this provider
  /// is what the view paints, and it must be checked before deciding to show a
  /// spinner.
  RawPixelsImage? get currentDecodedProvider =>
      _preloadController.pixelsProviderFor(_selectedItemID);

  /// The FULL-RESOLUTION provider for the current pixel-backed item, or null
  /// when its tier-2 upgrade has not landed (or was evicted). Non-null means a
  /// resident ImageCache entry for the item's CURRENT payload, so selecting it
  /// in the view is a cache hit, never a decode on the build path (M5 design
  /// §2.3). When it is null the view paints the window-resolution provider,
  /// which is honestly tier 1.
  ImageProvider? get currentFullResProvider =>
      _preloadController.fullResProviderFor(_selectedItemID);

  /// True when the current item's file could not be read at all (corrupt or
  /// unsupported). The view shows an error instead of a spinner.
  bool get currentItemFailed => _preloadController.hasFailed(_selectedItemID);

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
  // will request. Silent update, no notifyListeners: this doesn't change what
  // is displayed this frame, and it is written from inside a LayoutBuilder
  // builder where notifying would rebuild forever.
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
        // Warm the top of the list for a sidebar that hasn't laid out yet
        // (and for headless callers). Once the sidebar builds a frame it
        // reports its real visible range, which supersedes this.
        preloadThumbnails(0, 0);
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

  // [startIdx]..[endIdx] is the sidebar's VISIBLE row range; the controller
  // adds its own prefetch margin around it (see thumbnailPrefetchMargin).
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

  /// Exports every starred item as a <=2048px-long-edge JPEG into
  /// [destPath], reporting per-item progress on the status line. Does not
  /// reload the current folder: source files are untouched.
  Future<void> exportStarredThumbnails(String destPath) async {
    final dest = Directory(destPath);

    final outcome = await _exportService.exportStarred(
      _items,
      dest,
      onProgress: (done, total) {
        showStatus(StatusMessage('縮圖中 *$done/$total*…'));
      },
    );

    final folderName = p.basename(destPath);
    var message = '已匯出 *${outcome.exportedCount}* 張縮圖到 *$folderName*';
    if (outcome.failures.isNotEmpty) {
      message += '，*${outcome.failures.length}* 張失敗';
    }
    showStatus(StatusMessage(message, revealPath: destPath));
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

  Future<String?> loadSavedRenameRule() async {
    final dir = _currentDir;
    if (dir == null) return null;
    return _statusStore.loadRenameRule(dir);
  }

  /// Reads EXIF for [items], one read per item (from the JPG sibling when
  /// there is one — see [PhotoItem.bestFileToLoad]) and keyed by item id.
  /// The dialog uses this for its 5-file preview; [renameByExif] uses it for
  /// the whole folder.
  Future<Map<String, ExifMetadata?>> readMetadataFor(
    List<PhotoItem> items, {
    void Function(int done, int total)? onProgress,
  }) async {
    final paths = <String>[];
    final ids = <String>[];
    for (final item in items) {
      final file = item.bestFileToLoad;
      if (file == null) continue;
      ids.add(item.id);
      paths.add(file.path);
    }

    final out = <String, ExifMetadata?>{};
    for (var start = 0; start < paths.length; start += kExifChunkSize) {
      final end = (start + kExifChunkSize).clamp(0, paths.length);
      final chunk = await _exifReader(paths.sublist(start, end));
      for (var i = 0; i < chunk.length; i++) {
        out[ids[start + i]] = chunk[i];
      }
      onProgress?.call(end, paths.length);
    }
    return out;
  }

  /// Renames every photo in the current folder from [rule]. [isCustom] is
  /// true when the rule came from the editor rather than a built-in preset;
  /// only custom rules are remembered for the folder.
  Future<void> renameByExif(RenameRule rule, {required bool isCustom}) async {
    final dir = _currentDir;
    if (dir == null || _items.isEmpty || _isRenaming) return;

    _isRenaming = true;
    _renameCancelled = false;
    notifyListeners();

    try {
      final metadata = await readMetadataFor(
        _items,
        onProgress: (done, total) {
          showStatus(StatusMessage('讀取 EXIF *$done/$total*…'));
        },
      );

      final fileModified = <String, DateTime>{};
      final existingNames = <String>{};
      for (final entity in dir.listSync()) {
        existingNames.add(p.basename(entity.path));
      }
      for (final item in _items) {
        final file = item.bestFileToLoad;
        if (file == null) continue;
        fileModified[item.id] = file.statSync().modified;
      }

      final plans = planRenames(
        items: _items,
        metadata: metadata,
        fileModified: fileModified,
        rule: rule,
        existingNames: existingNames,
      );

      if (plans.isEmpty) {
        showStatus(const StatusMessage('沒有檔案需要重新命名'));
        return;
      }

      // Assigned only after the early return: an empty batch must not clobber
      // the previous batch's undo map.
      _lastRenameIdMap = {for (final plan in plans) plan.oldId: plan.newId};

      final outcome = await applyRenames(
        plans,
        dir,
        onProgress: (done, total) {
          showStatus(
            StatusMessage(
              '重新命名 *$done/$total*…',
              actionLabel: '取消',
              onAction: cancelRename,
            ),
          );
        },
        isCancelled: () => _renameCancelled,
      );

      // The status file is keyed by item id (the basename), so without this
      // every star, trash mark and the last-viewed pointer would be orphaned.
      await _statusStore.remapKeys(dir, {
        for (final plan in plans) plan.oldId: plan.newId,
      });
      await _statusStore.saveRenameRule(dir, isCustom ? rule.template : null);

      final currentPlan = plans.where((x) => x.oldId == _selectedItemID);
      await loadFolder(
        dir,
        targetSelectionId: currentPlan.isEmpty
            ? _selectedItemID
            : currentPlan.first.newId,
      );

      var message = '已重新命名 *${outcome.renamedCount}* 個項目';
      if (outcome.cancelled) message += '（已取消）';
      if (outcome.failures.isNotEmpty) {
        message += '，*${outcome.failures.length}* 個失敗';
        for (final failure in outcome.failures.take(3)) {
          debugPrint('Rename failure: $failure');
        }
      }
      showStatus(
        StatusMessage(message, actionLabel: '還原', onAction: undoRename),
      );
    } catch (e) {
      showStatus(StatusMessage('重新命名失敗：$e'));
    } finally {
      _isRenaming = false;
      notifyListeners();
    }
  }

  /// Replays the folder's rename journal backwards. No-op when there is none.
  Future<void> undoRename() async {
    final dir = _currentDir;
    if (dir == null || _isRenaming) return;

    final logExists = File(p.join(dir.path, kRenameLogName)).existsSync();
    if (!logExists) {
      showStatus(const StatusMessage('沒有可還原的重新命名紀錄'));
      return;
    }

    final outcome = await undoLastRename(dir);

    // The journal is per FILE; the status file is keyed per ITEM (basename
    // without extension), so remap with the inverse of the batch's id map.
    await _statusStore.remapKeys(dir, {
      for (final entry in _lastRenameIdMap.entries) entry.value: entry.key,
    });
    _lastRenameIdMap = const {};

    await loadFolder(dir);
    showStatus(StatusMessage('已還原 *${outcome.renamedCount}* 個檔案的原始檔名'));
  }

  @override
  void dispose() {
    _viewDebounceTimer?.cancel();
    _preloadController.dispose();
    super.dispose();
  }
}
