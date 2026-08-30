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
import '../services/image_pipeline/dart_image_loader.dart';
import '../services/image_pipeline/dng_decode_contract.dart';
import '../services/image_pipeline/full_decoder_dispatch.dart';
import '../services/rename/exif_metadata_service.dart';
import '../services/image_pipeline/image_preload_controller.dart';
import '../services/image_pipeline/image_source_types.dart';
import '../services/image_pipeline/photo_payload.dart';
import '../services/image_pipeline/retention_policy.dart';
import '../services/library/photo_file_actions.dart';
import '../services/library/photo_library_scanner.dart';
import '../services/library/photo_status_store.dart';
import '../services/image_pipeline/raw_pixels_image.dart';
import '../models/rename_rule.dart';
import '../services/library/photo_export_service.dart';
import '../services/rename/rename_coordinator.dart';

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
    NativeImageLoad? imageLoader,
    DngFullDecoder? dngDecoder,
    PhotoExportService? exportService,
    ExifBatchReader? exifReader,
    RetentionPolicy retention = const RetentionPolicy.floor(),
    // Defaults to 1 for the same reason `retention` defaults to the shipped
    // floor: a test or a platform with no hardware reading behaves exactly as
    // it did before this setting existed.
    int laneCeiling = 1,
  }) : _laneCeiling = laneCeiling < 1 ? 1 : laneCeiling,
       _decodeLaneWidth = defaultLaneWidthFor(laneCeiling < 1 ? 1 : laneCeiling),
       _scanner = scanner ?? PhotoLibraryScanner(),
       _exifReader = exifReader ?? ExifMetadataService.readBatch,
       _statusStore = statusStore ?? PhotoStatusStore(),
       _fileActions = fileActions ?? PhotoFileActions(),
       _exportService =
           exportService ?? PhotoExportService(decoder: dngDecoder),
       _preloadController =
           preloadController ??
           ImagePreloadController(
             imageLoader: imageLoader ?? dartImageLoad,
             // Null until the app's composition root injects the pkg squad's
             // adapter. While null, a DNG with no embedded preview is a
             // permanent miss (M6 U-12) -- there is no legacy channel path
             // left to fall back to.
             dngDecoder: dngDecoder,
             // M6 P2.5b: the sidebar's sized RAW-decode fallback only exists
             // where the app has a decoder at all (a platform/test with no
             // dngDecoder stays on the uniform explicit miss).
             // Dispatching sized decoder (2026-08-28 phase 1): routes .tif to
             // package:image and everything else to the Ceyx engine. The
             // `dngDecoder == null` guard is unchanged -- a build or test with
             // no decoder keeps the uniform explicit miss.
             sidebarRawDecoder: dngDecoder == null
                 ? null
                 : halcyonSizedDecoder,
             retention: retention,
             decodeLaneWidth: defaultLaneWidthFor(laneCeiling < 1 ? 1 : laneCeiling),
           ) {
    _renameCoordinator = RenameCoordinator(
      statusStore: _statusStore,
      itemsOf: () => _items,
      dirOf: () => _currentDir,
      selectedIdOf: () => _selectedItemID,
      readMetadata: readMetadataFor,
      showStatus: showStatus,
      reloadFolder: loadFolder,
      notify: notifyListeners,
    );
    _initPrefs();
  }

  final PhotoLibraryScanner _scanner;
  final PhotoStatusStore _statusStore;
  final PhotoFileActions _fileActions;
  final ImagePreloadController _preloadController;
  final PhotoExportService _exportService;
  final ExifBatchReader _exifReader;
  late final RenameCoordinator _renameCoordinator;

  /// The policy actually in force. Read from the controller rather than the
  /// constructor argument, so an injected controller and this getter can
  /// never disagree.
  RetentionPolicy get retentionPolicy => _preloadController.retention;

  bool get isRenaming => _renameCoordinator.isRenaming;

  void cancelRename() => _renameCoordinator.cancelRename();

  Directory? _currentDir;
  List<PhotoItem> _items = [];
  String? _selectedItemID;
  Timer? _viewDebounceTimer;

  // Settings
  bool _autoAdvance = false;
  bool _overwriteExisting = true;
  final int _laneCeiling;
  int _decodeLaneWidth;
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
    // Clamp on READ, not only on write: a value persisted on a 28-core desktop
    // must not be applied verbatim after the folder moves to an 8-core laptop.
    // getInt() throws a TypeError if the stored value was written under a
    // different type (e.g. a corrupted or hand-edited prefs store) -- guard
    // that so a bad stored value falls back to the default width instead of
    // crashing app startup.
    int? storedLaneWidth;
    try {
      storedLaneWidth = _prefs?.getInt('decodeLaneWidth');
    } catch (_) {
      storedLaneWidth = null;
    }
    _decodeLaneWidth =
        (storedLaneWidth ?? defaultLaneWidthFor(_laneCeiling))
            .clamp(1, _laneCeiling);
    _preloadController.setDecodeLaneWidth(_decodeLaneWidth);
    notifyListeners();
  }

  // Zoom/animation state deliberately does NOT live here: it is pure view
  // state, owned by ZoomController (lib/views/zoom_controller.dart), which
  // MainScreen creates. See gotcha G-010 / Task 19.

  List<PhotoItem> get items => _items;
  String? get selectedItemID => _selectedItemID;
  Directory? get currentDir => _currentDir;
  bool get autoAdvance => _autoAdvance;
  bool get overwriteExisting => _overwriteExisting;

  bool get recycleMode => _recycleMode;

  int get decodeLaneWidth => _decodeLaneWidth;

  /// The largest width this machine allows (memory rung AND core count).
  int get maxDecodeLaneWidth => _laneCeiling;

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

  /// The selected photo, or null when nothing is selected AND when the
  /// selected id is no longer in [_items].
  ///
  /// This used to fall back to `_items.first`, which showed the user a
  /// different photo than the one their marks were about to be applied to,
  /// and threw `StateError` outright on an empty folder. Returning null is
  /// the honest answer; `main_detail_view.dart` already renders a spinner
  /// for it.
  ///
  /// Written as an explicit loop: `package:collection` is not a dependency
  /// of this project, so `firstWhereOrNull` is unavailable.
  PhotoItem? get currentItem {
    final id = _selectedItemID;
    if (id == null) return null;
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
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

  /// The provider the detail view should paint right now. Same object
  /// identity as [currentFullResProvider]/[currentDecodedProvider] — never
  /// constructs a provider (that would break the tier-1/tier-2 cache-key rule).
  ImageProvider? get displayProvider =>
      currentItemHasFullSize ? currentFullResProvider : currentDecodedProvider;

  /// True when the current item's file could not be read at all (corrupt or
  /// unsupported). The view shows an error instead of a spinner.
  bool get currentItemFailed => _preloadController.hasFailed(_selectedItemID);

  SourcePayload? thumbnailPayloadFor(String id) =>
      _preloadController.thumbnailPayloadFor(id);

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
  ///
  /// The same protection covers paths that only *look* like photos: [loadFolder]
  /// clears the folder, items and selection before it scans, so a string that
  /// merely ends in a supported extension but names nothing on disk would wipe
  /// the folder being culled and leave an empty view. Android's ACTION_VIEW
  /// supplies exactly that shape (a `content://` URI's opaque segment such as
  /// `/document/image:1234.jpg`), so both the file and its parent directory
  /// must exist before any state is touched. The check is a plain filesystem
  /// existence test with no platform branch — it holds identically everywhere.
  Future<void> openPhotoAtPath(String path) async {
    if (!SupportedPhotoFormats.isSupportedPath(path)) return;
    final file = File(path);
    if (!await file.exists()) return;
    if (!await file.parent.exists()) return;
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
        showStatus(const StatusMessage('此卷宗為*唯讀*，標記不會被儲存（檢查記憶卡的防寫鎖）'));
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
      showStatus(StatusMessage('無法讀取此卷宗：$e'));
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

  void setDecodeLaneWidth(int value) {
    _decodeLaneWidth = value.clamp(1, _laneCeiling);
    _prefs?.setInt('decodeLaneWidth', _decodeLaneWidth);
    _preloadController.setDecodeLaneWidth(_decodeLaneWidth);
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

  /// Reloads [dir] and puts the selection back where it was.
  ///
  /// Call this *after* a batch file operation. `PhotoFileActions` touches the
  /// filesystem only — it never mutates [_items] or `_selectedItemID` — so the
  /// selection read here is still the pre-operation one. [dir] must be the
  /// directory captured before the operation, not `_currentDir` re-read now:
  /// the folder to refresh is the folder that was mutated.
  Future<void> _reloadPreservingSelection(Directory dir) {
    final currentId = _selectedItemID;
    return loadFolder(
      dir,
      targetSelectionId: currentId,
      targetFallbackIndex: _items.indexWhere((i) => i.id == currentId),
    );
  }

  // Actions
  Future<void> processStarred(String destinationStr, bool move) async {
    final destDir = Directory(destinationStr);
    final dir = _currentDir;

    try {
      final outcome = await _fileActions.processStarred(
        _items,
        destDir,
        move: move,
        overwriteExisting: _overwriteExisting,
      );
      if (outcome.failures.isNotEmpty) {
        // Previously debugPrint only, so a read-only destination or a
        // permission-denied copy looked identical to a working app.
        for (final failure in outcome.failures.take(3)) {
          debugPrint('processStarred failure: $failure');
        }
        showStatus(StatusMessage('*${outcome.failures.length}* 個檔案處理失敗'));
      }
    } catch (e) {
      debugPrint("Error processing starred items: $e");
      showStatus(StatusMessage('檔案處理失敗：$e'));
    }

    if (dir != null) {
      await _reloadPreservingSelection(dir);
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
        final outcome = await _fileActions.deleteTrashed(_items);
        failures.addAll(outcome.failures);
      }
    } catch (e) {
      // Previously this only debugPrint()ed, so a card where the system trash
      // is unavailable looked like a broken app. Report it instead.
      failures.add('$e');
    }

    if (dir != null) {
      await _reloadPreservingSelection(dir);
    }

    return BatchDeleteResult(
      recycled: recycled,
      movedCount: movedCount,
      failures: failures,
      trashDirPath: trashDirPath,
    );
  }

  Future<String?> loadSavedRenameRule() =>
      _renameCoordinator.loadSavedRenameRule();

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

    // Chunking (and its progress reporting) lives in ExifMetadataService.
    // This used to chunk by the same fixed size as well, so a 1200-photo
    // folder ran a 500-item loop inside a 500-item loop.
    final all = await _exifReader(paths, onProgress: onProgress);
    final out = <String, ExifMetadata?>{};
    for (var i = 0; i < ids.length && i < all.length; i++) {
      out[ids[i]] = all[i];
    }
    return out;
  }

  /// Thin forwarder — see [RenameCoordinator].
  Future<void> renameByExif(RenameRule rule, {required bool isCustom}) =>
      _renameCoordinator.renameByExif(rule, isCustom: isCustom);

  /// Thin forwarder — see [RenameCoordinator].
  Future<void> undoRename() => _renameCoordinator.undoRename();

  @override
  void dispose() {
    _viewDebounceTimer?.cancel();
    _preloadController.dispose();
    super.dispose();
  }
}
