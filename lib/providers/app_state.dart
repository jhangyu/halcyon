import 'dart:io';
import 'dart:async';
// dart:typed_data is not imported: package:flutter/services.dart (added for
// LogicalKeyboardKey) already re-exports Uint8List.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ceyx/ceyx.dart' show CeyxEncodeService;
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/photo_item.dart';
import '../models/supported_photo_formats.dart';
import '../perf/perf_log.dart'; // PERF-INSTRUMENTATION
import '../services/image_pipeline/dart_image_loader.dart';
import '../services/image_pipeline/dng_decode_contract.dart';
import '../services/image_pipeline/idle_publish_scheduler.dart';
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
import '../models/shortcut_bindings.dart';
// LAYERING NOTE: this is the one view-layer import in AppState. `LayoutThemeId`
// is a plain enum with no widget dependencies, and it is declared beside the
// `LayoutTheme` contract it selects (deleting a theme = deleting its directory
// and its enum case, the deletion contract in layout_theme.dart). Persisting
// the id here is what the frozen appearance spec section 8 asks for; moving
// the enum into models/ purely to satisfy import direction would split that
// deletion contract across two directories for no behavioural gain.
import '../views/layout/layout_theme.dart' show LayoutThemeId;
import 'settings_snapshot.dart';
import '../services/library/photo_export_service.dart';
import '../services/platform/working_set_trim.dart';
import '../services/rename/rename_coordinator.dart';

/// Appearance defaults (frozen spec section 8). Named constants rather than
/// literals because three places must agree: the hydration fallback, the
/// malformed-value fallback, and [AppState.resetAllSettings].
const ThemeMode kDefaultThemeMode = ThemeMode.system;
const LayoutThemeId kDefaultLayoutThemeId = LayoutThemeId.gallery;

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

/// A single [showStatus] emission, tagged with a monotonically increasing
/// [seq] so back-to-back `==`-equal [StatusMessage]s still produce distinct
/// [StatusEvent]s and are not coalesced by [ValueNotifier].
@immutable
class StatusEvent {
  const StatusEvent(this.seq, this.message);
  final int seq;
  final StatusMessage message;
}

/// The idle window after which a selection's EXIF read starts. Mirrors the
/// tier-2 navigation debounce (`tierTwoNavigationDebounce`) so holding an
/// arrow key cannot spawn one isolate per photo; the caption for the photo the
/// user finally stops on is worth one batched read, the intermediate ones are
/// not.
const Duration kSelectionExifDebounce = Duration(milliseconds: 250);

class AppState extends ChangeNotifier {
  /// The SIDEBAR's landing signal, deliberately separate from
  /// `notifyListeners`.
  ///
  /// A thumbnail landing used to call `notifyListeners` (this file's
  /// `preloadThumbnails` passed it in verbatim), and the two top-level
  /// listeners are unscoped `context.watch<AppState>()` -- `main.dart`'s
  /// MaterialApp and `main_screen.dart`'s whole surface. So the cheapest and
  /// most frequent event in the app was routed through the most expensive
  /// rebuild path in the app.
  ///
  /// The PREVIEW path deliberately keeps `notifyListeners`: the viewer
  /// genuinely must rebuild when the photo on screen gains its payload.
  final ValueNotifier<int> thumbnailsRevision = ValueNotifier<int>(0);

  void _bumpThumbnails() {
    // Same disposed-after-fire hazard as the preview path's notifyListeners
    // guard above: a thumbnail-preload slot handed out before dispose() can
    // still fire afterwards, and thumbnailsRevision is disposed in dispose().
    if (_disposed) return;
    thumbnailsRevision.value++;
  }

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
  }) : _decodeLaneWidth = kDefaultDecodeLaneWidth,
       _scanner = scanner ?? PhotoLibraryScanner(),
       _exifReader = exifReader ?? ExifMetadataService.readBatch,
       _statusStore = statusStore ?? PhotoStatusStore(),
       _fileActions = fileActions ?? PhotoFileActions(),
       _exportService =
           exportService ?? PhotoExportService(decoder: dngDecoder),
       _publishScheduler = IdlePublishScheduler() {
    // An INJECTED controller is used as-is: whoever injected it already chose
    // its pacing seams, and rewiring them here would silently override a
    // test's deterministic fake frame clock with a real idle scheduler.
    _preloadController =
        preloadController ??
        ImagePreloadController(
          imageLoader: imageLoader ?? dartImageLoad,
          // Null until the app's composition root injects the pkg squad's
          // adapter. While null, a DNG with no embedded preview is a
          // permanent miss (M6 U-12) -- there is no legacy channel path
          // left to fall back to.
          dngDecoder: dngDecoder,
          // No sidebar decoder: USER RULING 2026-08-30 (contract D5) makes
          // the sidebar a CONSUMER of the shared q70 payload. The sized
          // 200px route it used to own is deleted -- measured NOT FASTER
          // than a full decode (ratio 0.916, payload-bench-report.md §4)
          // while costing a whole extra sensor decode outside the lane.
          retention: retention,
          decodeLaneWidth: kDefaultDecodeLaneWidth,
          // CONTRACT DELIVERABLES 1 AND 2. One scheduler, both seams: tier-1
          // registrations are drained at Priority.idle, and EXIF-orientation
          // compositing buys a slot from the same queue instead of running
          // the moment a decode result arrives.
          scheduleFrameCallback: _publishScheduler.schedule,
          compositeGate: _publishScheduler.awaitSlot,
        );
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
    // Derived once, from the policy main.dart already probed for. No second
    // RAM probe, and an injected controller cannot drift from it.
    _autoRetentionTier = tierForPolicy(retention);
    _initPrefs();
  }

  /// Test-only constructor: skips prefs hydration and native capability
  /// resolution entirely, seeding [_runtimeExportCapabilities] directly.
  /// [resolveExportCapabilities] talks to the real (or injected)
  /// [CeyxEncodeService], which `flutter test` cannot resolve outside a
  /// built app bundle -- this seam lets UI-filtering tests exercise
  /// [selectableExportFiletypes] without going anywhere near that call.
  @visibleForTesting
  AppState.forTesting({required Set<ExportFiletype> runtimeCapabilities})
    : _decodeLaneWidth = kDefaultDecodeLaneWidth,
      _scanner = PhotoLibraryScanner(),
      _exifReader = ExifMetadataService.readBatch,
      _statusStore = PhotoStatusStore(),
      _fileActions = PhotoFileActions(),
      _exportService = PhotoExportService(),
      _publishScheduler = IdlePublishScheduler() {
    _preloadController = ImagePreloadController(
      imageLoader: dartImageLoad,
      dngDecoder: null,
      retention: const RetentionPolicy.floor(),
      decodeLaneWidth: kDefaultDecodeLaneWidth,
      scheduleFrameCallback: _publishScheduler.schedule,
      compositeGate: _publishScheduler.awaitSlot,
    );
    _autoRetentionTier = tierForPolicy(const RetentionPolicy.floor());
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
    _runtimeExportCapabilities = runtimeCapabilities;
  }

  final PhotoLibraryScanner _scanner;
  final PhotoStatusStore _statusStore;
  final PhotoFileActions _fileActions;
  /// `late final`, assigned in the constructor body rather than the
  /// initialiser list: the controller is built with seams that read
  /// [_publishScheduler], and an initialiser list cannot touch `this`.
  late final ImagePreloadController _preloadController;

  /// THE app's single publish-pacing scheduler. Idle-priority slots for
  /// tier-1 ImageCache registration (through the pacer's frame hook) and for
  /// EXIF orientation compositing (through the composite gate), so publish
  /// work stops landing as bursts while the user scrolls or arrows through
  /// photos.
  final IdlePublishScheduler _publishScheduler;

  @visibleForTesting
  IdlePublishScheduler get debugPublishScheduler => _publishScheduler;

  /// Signals the idle-publish scheduler that the user is actively
  /// interacting right now (residual-jank-diagnosis.md fix #6). [selectItem]
  /// (keyboard/programmatic navigation) already calls this; pointer/scroll
  /// wiring lives in the views layer and is a follow-up outside this file's
  /// ownership boundary.
  void noteInputActivity() => _publishScheduler.noteInputActivity();

  /// One mechanically checkable answer to "is production actually paced"
  /// (contract AC1), so the test does not have to read private state.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  bool get debugPublishPacingWired =>
      // ignore: invalid_use_of_visible_for_testing_member
      _preloadController.debugPacerHasFrameHook &&
      // ignore: invalid_use_of_visible_for_testing_member
      _preloadController.debugCompositeGateIsPaced;

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

  // Per-selection EXIF (T13): EXIF for the currently selected photo, read
  // through the SAME [_exifReader] the rename dialog uses. Deliberately NOT a
  // second constructor parameter: the reader determines what a caption can
  // know only after 250ms of navigation quiet — see [readMetadataFor].
  //
  // [_exifCache] is id -> metadata, unbounded WITHIN a folder: a revisited
  // photo never re-reads, and a folder re-loads through [loadFolder] (not a
  // lifetime that could leak across folders). [_exifGeneration] is the
  // staleness guard: it bumps on every selection change AND every folder
  // switch, and a read whose result arrives under an older generation is
  // discarded instead of written. One guard that is also folded into the
  // debounce, so a stale read cannot even disarm the current item's pending
  // read early.
  final Map<String, ExifMetadata?> _exifCache = <String, ExifMetadata?>{};
  int _exifGeneration = 0;
  Timer? _exifDebounceTimer;

  // Settings
  bool _autoAdvance = false;
  bool _overwriteExisting = true;
  int _decodeLaneWidth;
  int _exportJpegQuality = kDefaultExportJpegQuality;
  int _exportLongEdge = kDefaultExportLongEdge;
  ExportFiletype _exportFiletype = kDefaultExportFiletype;

  /// The user's actual intent for [exportFiletype] -- the persisted pref
  /// name at hydration time, or the name last passed to [setExportFiletype].
  /// Runtime capability is not known yet when [_initPrefs] first computes
  /// [_exportFiletype] (see [resolveExportCapabilities]'s doc), so that
  /// first computation can downgrade to the default; without recording the
  /// ORIGINAL name separately, [resolveExportCapabilities] would renormalise
  /// from the already-downgraded `_exportFiletype.name` once capability
  /// resolves, and could never recover the user's real preference.
  String? _exportFiletypeIntentName;

  /// Formats the loaded native library can actually encode, resolved ONCE at
  /// startup by [resolveExportCapabilities]. Empty until that completes; the
  /// [selectableExportFiletypes] getter below therefore falls back to JPEG,
  /// which libjpeg-turbo always provides.
  Set<ExportFiletype> _runtimeExportCapabilities = const {};

  /// Set by [dispose]. [resolveExportCapabilities] is fired-and-forgotten
  /// from [_initPrefs] and may still be awaiting its native probe when this
  /// object is disposed (short-lived tests, a view torn down mid-startup);
  /// this flag lets it bail out instead of calling `notifyListeners()` on a
  /// disposed `ChangeNotifier`, which throws.
  bool _disposed = false;
  /// Appearance, persisted (frozen spec section 8). Defaults: system / gallery.
  ThemeMode _themeMode = kDefaultThemeMode;
  LayoutThemeId _layoutThemeId = kDefaultLayoutThemeId;

  RetentionTier? _retentionTierOverride;
  late final RetentionTier _autoRetentionTier;
  ShortcutBindings _shortcuts = ShortcutBindings.defaults();
  SharedPreferences? _prefs;

  // Per-folder, deliberately NOT persisted: every loadFolder re-detects, so
  // a new card always starts from the safe default.
  bool _recycleMode = false;

  // The status line's current message. [_statusSeq] bumps on every show so the
  // view can restart its timer even when the same text repeats.
  StatusMessage? _status;
  int _statusSeq = 0;

  /// Fires once per [showStatus] call (see [StatusEvent]); [StatusLine]
  /// listens to this instead of the whole-app [notifyListeners] stream.
  final ValueNotifier<StatusEvent?> statusEvents = ValueNotifier(null);

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
    final storedLaneWidth = _readIntPref('decodeLaneWidth');
    _decodeLaneWidth = (storedLaneWidth ?? kDefaultDecodeLaneWidth).clamp(
      1,
      kMaxDecodeLaneWidth,
    );
    _preloadController.setDecodeLaneWidth(_decodeLaneWidth);

    // Each read below stands alone: a corrupt export quality must not take
    // down the retention tier, and one bad shortcut entry costs one binding.
    _exportJpegQuality = _normaliseExportQuality(_readIntPref('exportJpegQuality'));
    _exportService.jpegQuality = _exportJpegQuality;

    _exportLongEdge = _normaliseExportLongEdge(_readIntPref('exportLongEdge'));
    _exportService.longEdge = _exportLongEdge;

    _exportFiletypeIntentName = _readStringPref('exportFiletype');
    _exportFiletype = _normaliseExportFiletype(_exportFiletypeIntentName);
    _exportService.filetype = _exportFiletype;
    // Fire-and-forget: resolving runtime capability requires a native call
    // that must not block prefs hydration/first paint. It normalises
    // `_exportFiletype` again and notifies once it completes (see doc on
    // [resolveExportCapabilities]).
    unawaited(resolveExportCapabilities());

    _themeMode = _themeModeFromName(_readStringPref('themeMode'));
    _layoutThemeId = _layoutThemeIdFromName(_readStringPref('layoutThemeId'));

    final tierId = _readStringPref('retentionTier');
    _retentionTierOverride = tierId == null ? null : retentionTierFromId(tierId);
    _preloadController.setRetention(retentionPolicyForTier(retentionTier));

    var bindings = ShortcutBindings.defaults();
    for (final action in ShortcutAction.values) {
      final keyId = _readIntPref(action.prefsKey);
      if (keyId != null) {
        // An unknown keyId yields a synthetic key that matches nothing; that
        // is strictly better than dropping the other six bindings.
        bindings = bindings.withBinding(action, LogicalKeyboardKey(keyId));
      }
    }
    _shortcuts = bindings;

    // Guards the same race documented on resolveExportCapabilities (:514):
    // this method awaits SharedPreferences.getInstance() before reaching
    // here, and a short-lived AppState (e.g. a test) may already be disposed
    // by the time that resolves -- notifyListeners() on a disposed
    // ChangeNotifier throws.
    if (_disposed) return;
    notifyListeners();
  }

  /// getInt/getString throw a TypeError when the stored value was written
  /// under a different type (a corrupted or hand-edited prefs store); one
  /// guarded-read idiom instead of six copies of the try/catch.
  int? _readIntPref(String key) {
    try {
      return _prefs?.getInt(key);
    } catch (_) {
      return null; // wrong stored type; fall back to the default
    }
  }

  String? _readStringPref(String key) {
    try {
      return _prefs?.getString(key);
    } catch (_) {
      return null;
    }
  }

  /// Unknown / malformed stored values fall back to the default rather than
  /// throwing, matching every other read in [_initPrefs].
  static ThemeMode _themeModeFromName(String? raw) {
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return kDefaultThemeMode;
  }

  static LayoutThemeId _layoutThemeIdFromName(String? raw) {
    for (final id in LayoutThemeId.values) {
      if (id.name == raw) return id;
    }
    return kDefaultLayoutThemeId;
  }

  int _normaliseExportQuality(int? raw) =>
      raw == null ? kDefaultExportJpegQuality : ((raw / 5).round() * 5).clamp(50, 100);

  /// Unlike quality, the size stops are not evenly spaced (and 0 is a
  /// sentinel, not a size), so this is a set-membership check rather than a
  /// round-to-nearest -- an unrecognised stored value falls back to the
  /// default instead of snapping to a neighbour.
  int _normaliseExportLongEdge(int? raw) =>
      raw != null && kExportLongEdgeStops.contains(raw)
          ? raw
          : kDefaultExportLongEdge;

  /// Falls back to the default for a garbage/unknown name AND for a
  /// recognised-but-runtime-unavailable one (see [ExportFiletype]'s doc): a
  /// value this build cannot encode must never be applied, whether it
  /// arrived from a corrupt pref or from an older/different build of this
  /// app whose capability set differs from this one's.
  ExportFiletype _normaliseExportFiletype(String? raw) {
    for (final type in ExportFiletype.values) {
      if (type.name == raw) {
        return selectableExportFiletypes.contains(type)
            ? type
            : kDefaultExportFiletype;
      }
    }
    return kDefaultExportFiletype;
  }

  // Zoom/animation state deliberately does NOT live here: it is pure view
  // state, owned by ZoomController (lib/views/zoom_controller.dart), which
  // MainScreen creates. See gotcha G-010 / Task 19.

  List<PhotoItem> get items => _items;

  /// How many items in the loaded folder are starred / trashed. Computed by a
  /// linear scan on every read: a folder holds hundreds to a few thousand
  /// items, so two scans per frame cost nothing next to a decode, and an
  /// incrementally maintained counter would need `loadFolder`, `markCurrent`,
  /// `recycleTrashed` and `deleteTrashed` to all keep a second source of
  /// truth in sync.
  int get starredCount =>
      _items.where((item) => item.status == PhotoStatus.starred).length;

  int get trashedCount =>
      _items.where((item) => item.status == PhotoStatus.trashed).length;
  String? get selectedItemID => _selectedItemID;
  Directory? get currentDir => _currentDir;
  bool get autoAdvance => _autoAdvance;

  /// Drives `MaterialApp.themeMode` (main.dart). `system` resolves through the
  /// platform brightness, so this is the stored intent, not the rendering.
  ThemeMode get themeMode => _themeMode;

  /// Selects which [LayoutTheme] the whole app arranges itself with, via
  /// `layoutThemeFor`. Replaced the `kActiveLayoutThemeId` constant.
  LayoutThemeId get layoutThemeId => _layoutThemeId;
  bool get overwriteExisting => _overwriteExisting;

  bool get recycleMode => _recycleMode;

  int get decodeLaneWidth => _decodeLaneWidth;

  /// The largest width the user may set. Fixed on every platform (AD-044).
  int get maxDecodeLaneWidth => kMaxDecodeLaneWidth;

  int get exportJpegQuality => _exportJpegQuality;

  int get exportLongEdge => _exportLongEdge;

  ExportFiletype get exportFiletype => _exportFiletype;

  /// Build intent INTERSECTED with runtime capability (ruling Q4). The
  /// settings panel's segmented control and [_normaliseExportFiletype] both
  /// read this, not [ExportFiletype.buildIntent] alone.
  List<ExportFiletype> get selectableExportFiletypes {
    final caps = _runtimeExportCapabilities;
    if (caps.isEmpty) return const [kDefaultExportFiletype];
    return ExportFiletype.values
        .where((f) => f.buildIntent && caps.contains(f))
        .toList();
  }

  /// Probes the native library once. Safe to call before the dylib exists:
  /// every failure degrades to "only the default is offered" rather than
  /// throwing, matching the never-throws contract the probe layer already
  /// has.
  Future<void> resolveExportCapabilities({CeyxEncodeService? service}) async {
    final svc = service ?? CeyxEncodeService();
    final found = <ExportFiletype>{};
    for (final ft in ExportFiletype.values) {
      if (!ft.buildIntent) continue;
      if (await svc.supports(ft.format)) found.add(ft);
    }
    // The probe above is fired-and-forgotten from `_initPrefs`/the app-startup
    // caller; by the time every `supports()` call has resolved this AppState
    // may already have been disposed (a short-lived test, or a view torn
    // down mid-startup) -- `notifyListeners()` on a disposed ChangeNotifier
    // throws, so this must bail out instead of touching state or listeners.
    if (_disposed) return;
    _runtimeExportCapabilities = found.isEmpty ? const {} : found;
    // Re-normalise from the ORIGINAL intent name, not `_exportFiletype.name`:
    // `_initPrefs` may already have downgraded `_exportFiletype` to the
    // default before capability was known, and renormalising from that
    // already-downgraded name would permanently discard the user's real
    // preference the moment it turns out to be runtime-available.
    _exportFiletype =
        _normaliseExportFiletype(_exportFiletypeIntentName ?? _exportFiletype.name);
    _exportService.filetype = _exportFiletype;
    notifyListeners();
  }

  /// The tier this machine derives from its own RAM, i.e. what "Auto" means.
  RetentionTier get autoRetentionTier => _autoRetentionTier;
  RetentionTier get retentionTier => _retentionTierOverride ?? _autoRetentionTier;
  bool get isRetentionTierOverridden => _retentionTierOverride != null;
  ShortcutBindings get shortcutBindings => _shortcuts;

  StatusMessage? get status => _status;
  int get statusSeq => _statusSeq;

  void showStatus(StatusMessage message) {
    _status = message;
    _statusSeq++;
    statusEvents.value = StatusEvent(_statusSeq, message);
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

  /// EXIF for the currently selected photo, or null while unread/unreadable.
  ///
  /// A caption's single source of truth: the last read that LANDED for this
  /// selection (or null when navigation is still in flight, the read has not
  /// been started by the debounce yet, or the read failed). Never reflects a
  /// different photo: reads land under the generation they were started with
  /// ([_exifGeneration]), and that generation increments on every selection
  /// and folder change, so a stale result is discarded before it can be
  /// exposed here.
  ExifMetadata? get currentExif {
    final id = _selectedItemID;
    if (id == null) return null;
    return _exifCache[id];
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
    // Per-folder EXIF cache, cleared with every folder switch: ids are not
    // globally unique (a card from one shoot and a card from another both hold
    // "IMG_0001"), so an entry cached under the old folder's "IMG_0001" must
    // not be read out for the new one. Bumped BEFORE the first await so any
    // in-flight read from the previous folder is discarded on land.
    _exifCache.clear();
    _exifGeneration++;
    _exifDebounceTimer?.cancel();
    _exifDebounceTimer = null;
    // The single largest release moment in the app: reset() has just evicted
    // both ImageCache tiers and dropped every retained payload, and nothing is
    // about to be re-read, so the page re-fault cost is minimal. Deliberately
    // bypasses the rate limit.
    WorkingSetTrim.trimNow();
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
      noteInputActivity();
      final tEnter = PerfLog.us; // PERF-INSTRUMENTATION
      PerfLog.log('selectItem.enter|$id'); // PERF-INSTRUMENTATION
      // PERF-INSTRUMENTATION (D1 AC3 marker): navigation/selection event.
      // Round-1 review fix (MEDIUM): the indexWhere scan is O(n) and used to
      // run unconditionally, adding a second full-list scan per keypress on
      // top of nextPhoto/previousPhoto's own even with logging OFF. Guarded
      // on `PerfLog.enabled` (not `kPerfLog` alone: the PerfDriver/
      // HALCYON_PERF_DIR path enables logging without the const flag).
      if (PerfLog.enabled) {
        final navIdx = _items.indexWhere((item) => item.id == id);
        PerfLog.log('nav|id=$id|index=$navIdx');
      }
      _selectedItemID = id;
      // PERF-INSTRUMENTATION
      final cached = _preloadController.imageBytesFor(id);
      PerfLog.log(
        'cache.${cached != null ? "hit" : "miss"}|$id|${cached?.length ?? 0}',
      );
      _preloadImages();
      _scheduleExifRead();

      _viewDebounceTimer?.cancel();
      _viewDebounceTimer = Timer(const Duration(seconds: 5), _saveLastViewedId);
      // Reuses this existing "the user has moved" site. The trim's own 2s idle
      // delay plus 10s rate limit keep it off the navigation hot path; it is a
      // no-op off Windows.
      WorkingSetTrim.request();

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
    _decodeLaneWidth = value.clamp(1, kMaxDecodeLaneWidth);
    _prefs?.setInt('decodeLaneWidth', _decodeLaneWidth);
    _preloadController.setDecodeLaneWidth(_decodeLaneWidth);
    notifyListeners();
  }

  void setExportJpegQuality(int quality) {
    _exportJpegQuality = _normaliseExportQuality(quality);
    _prefs?.setInt('exportJpegQuality', _exportJpegQuality);
    _exportService.jpegQuality = _exportJpegQuality;
    notifyListeners();
  }

  void setExportLongEdge(int longEdge) {
    _exportLongEdge = _normaliseExportLongEdge(longEdge);
    _prefs?.setInt('exportLongEdge', _exportLongEdge);
    _exportService.longEdge = _exportLongEdge;
    notifyListeners();
  }

  void setExportFiletype(ExportFiletype filetype) {
    // Record the user's real intent BEFORE gating: a later
    // resolveExportCapabilities() re-normalises from this name, so an
    // explicit pick a capability probe hasn't caught up with yet is not
    // lost the way a persisted-but-unresolved pref would be.
    _exportFiletypeIntentName = filetype.name;
    _exportFiletype = selectableExportFiletypes.contains(filetype)
        ? filetype
        : kDefaultExportFiletype;
    _prefs?.setString('exportFiletype', _exportFiletype.name);
    _exportService.filetype = _exportFiletype;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    _prefs?.setString('themeMode', mode.name);
    notifyListeners();
  }

  void setLayoutThemeId(LayoutThemeId id) {
    _layoutThemeId = id;
    _prefs?.setString('layoutThemeId', id.name);
    notifyListeners();
  }

  void setRetentionTier(RetentionTier tier) {
    _retentionTierOverride = tier;
    _prefs?.setString('retentionTier', tier.id);
    _preloadController.setRetention(retentionPolicyForTier(tier));
    notifyListeners();
  }

  void resetRetentionTierToAuto() {
    _retentionTierOverride = null;
    _prefs?.remove('retentionTier');
    _preloadController.setRetention(retentionPolicyForTier(_autoRetentionTier));
    notifyListeners();
  }

  void setShortcutBinding(ShortcutAction action, LogicalKeyboardKey key) {
    // Conflicts are ACCEPTED here by design: the panel warns and dispatch has
    // a deterministic winner (ShortcutBindings.actionFor). Blocking would make
    // the mockup's warning state unreachable.
    _shortcuts = _shortcuts.withBinding(action, key);
    _prefs?.setInt(action.prefsKey, key.keyId);
    notifyListeners();
  }

  void resetShortcutBinding(ShortcutAction action) {
    _shortcuts = _shortcuts.withDefault(action);
    _prefs?.remove(action.prefsKey);
    notifyListeners();
  }

  /// Restores every persisted preference to its default and wipes the store.
  ///
  /// Deliberately NOT expressed as a snapshot restore: the settings dialog's
  /// revert-on-dismiss contract captures a snapshot when it opens, so a reset
  /// that went through the ordinary setters would still be undone by that
  /// snapshot on dismissal. The caller is required to set the dialog's
  /// committed flag before popping (frozen spec section 7); this method's job
  /// is only to make the in-memory state and the store agree on the defaults.
  ///
  /// `clear()` removes every key this app has ever written, including keys no
  /// longer read by this version — that is the intent of "reset ALL settings",
  /// and it is why the fields below are reset explicitly rather than by
  /// re-running [_initPrefs] (which would race the async store).
  ///
  /// Star and trash marks are NOT touched: they live in each photo folder's
  /// own `.halcyon_status.json`, which this method never opens.
  Future<void> resetAllSettings() async {
    _themeMode = kDefaultThemeMode;
    _layoutThemeId = kDefaultLayoutThemeId;
    _autoAdvance = false;
    _overwriteExisting = true;
    _decodeLaneWidth = kDefaultDecodeLaneWidth;
    _exportJpegQuality = kDefaultExportJpegQuality;
    _exportLongEdge = kDefaultExportLongEdge;
    _exportFiletype = kDefaultExportFiletype;
    _exportFiletypeIntentName = null;
    _retentionTierOverride = null;
    _shortcuts = ShortcutBindings.defaults();

    // The collaborators hold their own copies; resetting the field without
    // pushing it through is how a "reset" leaves the pipeline on the old
    // value while the panel claims otherwise.
    _preloadController.setDecodeLaneWidth(_decodeLaneWidth);
    _preloadController.setRetention(retentionPolicyForTier(retentionTier));
    _exportService.jpegQuality = _exportJpegQuality;
    _exportService.longEdge = _exportLongEdge;
    _exportService.filetype = _exportFiletype;

    notifyListeners();
    // Awaited last: the in-memory reset and the notify must not wait on disk,
    // but the future is returned so a caller (and a test) can await the store
    // actually being empty.
    await _prefs?.clear();
  }

  void resetAllShortcutBindings() {
    _shortcuts = ShortcutBindings.defaults();
    for (final action in ShortcutAction.values) {
      _prefs?.remove(action.prefsKey);
    }
    notifyListeners();
  }

  SettingsSnapshot settingsSnapshot() => SettingsSnapshot(
        themeMode: _themeMode,
        layoutThemeId: _layoutThemeId,
        autoAdvance: _autoAdvance,
        overwriteExisting: _overwriteExisting,
        decodeLaneWidth: _decodeLaneWidth,
        exportJpegQuality: _exportJpegQuality,
        exportLongEdge: _exportLongEdge,
        exportFiletype: _exportFiletype,
        retentionTierOverride: _retentionTierOverride,
        shortcuts: _shortcuts,
      );

  /// Puts every panel-changeable field back, prefs included.
  ///
  /// Each field goes back through its ordinary setter, so no path can revert
  /// in-memory state while leaving the persisted value changed.
  void restoreSettings(SettingsSnapshot snapshot) {
    if (snapshot.themeMode != _themeMode) setThemeMode(snapshot.themeMode);
    if (snapshot.layoutThemeId != _layoutThemeId) {
      setLayoutThemeId(snapshot.layoutThemeId);
    }
    if (snapshot.autoAdvance != _autoAdvance) setAutoAdvance(snapshot.autoAdvance);
    if (snapshot.overwriteExisting != _overwriteExisting) {
      setOverwriteExisting(snapshot.overwriteExisting);
    }
    if (snapshot.decodeLaneWidth != _decodeLaneWidth) {
      setDecodeLaneWidth(snapshot.decodeLaneWidth);
    }
    if (snapshot.exportJpegQuality != _exportJpegQuality) {
      setExportJpegQuality(snapshot.exportJpegQuality);
    }
    if (snapshot.exportLongEdge != _exportLongEdge) {
      setExportLongEdge(snapshot.exportLongEdge);
    }
    if (snapshot.exportFiletype != _exportFiletype) {
      setExportFiletype(snapshot.exportFiletype);
    }
    if (snapshot.retentionTierOverride != _retentionTierOverride) {
      final tier = snapshot.retentionTierOverride;
      if (tier == null) {
        resetRetentionTierToAuto();
      } else {
        setRetentionTier(tier);
      }
    }
    if (snapshot.shortcuts != _shortcuts) {
      for (final action in ShortcutAction.values) {
        final key = snapshot.shortcuts.keyFor(action);
        if (_shortcuts.keyFor(action) == key) continue;
        if (key == action.defaultKey) {
          resetShortcutBinding(action);
        } else {
          setShortcutBinding(action, key);
        }
      }
    }
    notifyListeners();
  }

  // Preload sliding window: Previous 3, Current, Next 5
  Future<void> _preloadImages() async {
    final selectedId = _selectedItemID;
    if (selectedId == null) return;

    await _preloadController.preloadImages(
      items: _items,
      selectedItemId: selectedId,
      // Guarded rather than a bare `notifyListeners` reference: preload work
      // fans out through idle-scheduler slots and lane awaits, so a callback
      // handed out before dispose() can still fire afterwards (observed on
      // Windows CI as "A AppState was used after being disposed" from
      // ImagePreloadController._flushPendingNotifies -- the controller has no
      // way to know the notifier it was given has since been torn down).
      notifyLoaded: () {
        if (!_disposed) notifyListeners();
      },
    );
  }

  // [startIdx]..[endIdx] is the sidebar's VISIBLE row range; the controller
  // adds its own prefetch margin around it (see thumbnailPrefetchMargin).
  Future<void> preloadThumbnails(int startIdx, int endIdx) async {
    await _preloadController.preloadThumbnails(
      items: _items,
      startIdx: startIdx,
      endIdx: endIdx,
      notifyLoaded: _bumpThumbnails,
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
    final intendedRecycle = _recycleMode;
    // The branch actually taken below depends on both the intent flag AND
    // `dir != null`; feedback (recycled field) must reflect that actual
    // branch, not just the intent flag, or it can claim recycling happened
    // when the fallback direct-delete branch ran instead.
    final tookRecycleBranch = intendedRecycle && dir != null;

    var movedCount = 0;
    final failures = <String>[];
    String? trashDirPath;

    try {
      if (tookRecycleBranch) {
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
      recycled: tookRecycleBranch,
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

  /// Arms the 250ms quiet debounce for the current selection's EXIF read.
  ///
  /// Every selection change cancels and re-arms the timer, so only the photo
  /// the user finally STOPS on gets read — the photos merely passed through
  /// never reach the reader. Mirrors the tier-2 debounce so holding an arrow
  /// key cannot spawn one isolate per photo.
  void _scheduleExifRead() {
    final id = _selectedItemID;
    if (id == null) {
      _exifDebounceTimer?.cancel();
      _exifDebounceTimer = null;
      return;
    }
    // A revisited photo never re-reads: the cache already holds its answer.
    if (_exifCache.containsKey(id)) return;
    // Every navigation event supersedes the ones before it: bump the
    // generation NOW (before any await), so a read that later lands for an
    // older selection is discarded on arrival instead of being written over
    // the current photo's entry.
    _exifGeneration++;
    final generation = _exifGeneration;
    _exifDebounceTimer?.cancel();
    _exifDebounceTimer = Timer(kSelectionExifDebounce, () {
      _readSelectionExif(id, generation);
    });
  }

  /// Fires one batched EXIF read for the selection captured by the debounce.
  ///
  /// The reader is [_exifReader] — the same injected seam the rename dialog
  /// uses ([readMetadataFor]) — carrying a ONE-element path list because that
  /// is what a batch-shaped seam takes; the element's metadata is pulled back
  /// out and keyed by the item id. The single-element list is the price of not
  /// adding a second single-path injection parameter to [AppState]: one
  /// reader, one way to fake it (round1-plan T13).
  ///
  /// [generation] is the selection's generation captured at schedule time; if
  /// the selection (or folder) changed since, the result is for a photo nobody
  /// is looking at and is discarded. Checked BEFORE any branch so every write
  /// (the null-file `null` cache and the real read) is generation-protected,
  /// then again after the reader await so the stale read cannot notify for the
  /// current photo.
  Future<void> _readSelectionExif(String id, int generation) async {
    if (generation != _exifGeneration) return;
    final item = currentItem;
    if (item == null || item.id != id) return;
    // A read already landed for this selection (or was cached as unreadable):
    // the caption is settled, do not buy the read again.
    if (_exifCache.containsKey(id)) return;
    final file = item.bestFileToLoad;
    if (file == null) {
      _exifCache[id] = null;
      return;
    }

    List<ExifMetadata?> all;
    try {
      all = await _exifReader([file.path]);
    } catch (_) {
      // A reader that throws is treated as "nothing to show": the caption
      // stays empty rather than crashing the app over a caption.
      all = const [null];
    }
    if (generation != _exifGeneration) return;
    _exifCache[id] = all.isEmpty ? null : all.first;
    // Exactly one notify on landing: the selection moved once, the caption
    // appears once.
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _viewDebounceTimer?.cancel();
    _exifDebounceTimer?.cancel();
    _preloadController.dispose();
    // AFTER the controller: its dispose clears the pacer, and this flushes
    // whatever slot was still pending. The reverse order would flush a
    // publish into a torn-down controller.
    _publishScheduler.dispose();
    statusEvents.dispose();
    thumbnailsRevision.dispose();
    super.dispose();
  }
}
