import 'dart:io';
import 'dart:async';
// dart:typed_data is not imported: package:flutter/services.dart (added for
// LogicalKeyboardKey) already re-exports Uint8List.
import 'package:flutter/foundation.dart' show ValueListenable;
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
// R4 item 1: the advisory decode-width recommendations the settings dialog
// displays. Read-only accessor; it carries no clamping authority.
import '../services/image_pipeline/dng_decode_service.dart'
    show halcyonDecodeWidthRecommendations;
import '../services/image_pipeline/idle_publish_scheduler.dart';
import '../services/rename/exif_metadata_service.dart';
import '../services/image_pipeline/image_preload_controller.dart';
import '../services/image_pipeline/image_source_types.dart';
import '../services/image_pipeline/memory_ledger_snapshot.dart';
import '../services/image_pipeline/payload_state.dart';
import '../services/image_pipeline/photo_payload.dart';
import '../services/image_pipeline/retention_policy.dart';
import '../services/library/photo_file_actions.dart';
import '../services/library/photo_library_scanner.dart';
import '../services/library/photo_status_store.dart';
import '../services/image_pipeline/raw_pixels_image.dart';
import '../models/rename_rule.dart';
import '../models/status_message.dart';
import '../models/shortcut_bindings.dart';
// LayoutThemeId: see the LAYERING NOTE in app_settings.dart.
import '../views/layout/layout_theme.dart' show LayoutThemeId;
import 'app_settings.dart';
import '../services/library/photo_export_service.dart';
import '../services/platform/working_set_trim.dart';
import '../services/rename/rename_coordinator.dart';

/// The idle window after which a selection's EXIF read starts. Mirrors the
/// tier-2 navigation debounce (`tierTwoNavigationDebounce`) so holding an
/// arrow key cannot spawn one isolate per photo; the caption for the photo the
/// user finally stops on is worth one batched read, the intermediate ones are
/// not.
const Duration kSelectionExifDebounce = Duration(milliseconds: 250);

class AppState extends ChangeNotifier {
  // PHASE 5 (commit B): the sidebar's strip-wide landing signal
  // (`thumbnailsRevision`, a ValueNotifier<int> every theme wrapped its whole
  // strip in) is GONE. A tile landing now wakes exactly one row through
  // `ImagePreloadController.stateFor(id)` -> `StripTile`, so the fan-out this
  // field existed to narrow -- one landing rebuilding 40 rows -- has no
  // remaining producer to narrow.
  //
  // The PREVIEW path no longer calls `notifyListeners` either (see
  // [_preloadImages]): as of P1 (2026-09-06) a landing wakes exactly the item
  // that landed through [payloadStateFor], which `photo_viewport.dart`
  // already consumes via `ValueListenableBuilder`. The removal was gated on
  // fixing two payload-state races the old app-wide notify was masking (see
  // docs/logs/2026-09-06/p3-plan-P1.md); with those fixed, no unscoped
  // `context.watch<AppState>()` consumer in the app depends on payload
  // landing (enumerated: TC-1014's sign-off report).

  AppState({
    PhotoLibraryScanner? scanner,
    PhotoStatusStore? statusStore,
    PhotoFileActions? fileActions,
    ImagePreloadController? preloadController,
    NativeImageLoad? imageLoader,
    DngFullDecoder? dngDecoder,
    // Task 8 (native-rotation-spec, round 3): mirrors [dngDecoder]'s own
    // wiring rule exactly -- no production default is baked in HERE. The
    // composition root (main.dart) is responsible for passing
    // `halcyonOrientingFullDecoder` alongside `halcyonFullDecoder`; leaving
    // this null keeps every existing caller of this constructor (tests
    // included) byte-identical until that root chooses to inject one.
    DngOrientingFullDecoder? orientingDngDecoder,
    PhotoExportService? exportService,
    ExifBatchReader? exifReader,
    RetentionPolicy retention = const RetentionPolicy.floor(),
    // Forwarded straight to the preload controller, where it is the SAFETY
    // CEILING of the decode byte budget and nothing else (decision D1-a,
    // 2026-09-11). Optional with a null default so no test needs a RAM fake;
    // `main.dart` passes the one reading it already took.
    int? physicalMemoryBytes,
    // Test-only seam: lets tests shrink the 250ms selection-EXIF quiet period
    // instead of waiting it out in real time. Production callers must not pass
    // this. Precedent: ImagePreloadController.navigationDebounce.
    Duration exifDebounce = kSelectionExifDebounce,
  }) : this._(
          scanner: scanner,
          statusStore: statusStore,
          fileActions: fileActions,
          preloadController: preloadController,
          imageLoader: imageLoader,
          dngDecoder: dngDecoder,
          orientingDngDecoder: orientingDngDecoder,
          exportService: exportService,
          exifReader: exifReader,
          retention: retention,
          physicalMemoryBytes: physicalMemoryBytes,
          exifDebounce: exifDebounce,
          hydrate: true,
        );

  /// Test-only constructor: skips prefs hydration and native capability
  /// resolution entirely, seeding [_runtimeExportCapabilities] directly.
  /// [resolveExportCapabilities] talks to the real (or injected)
  /// [CeyxEncodeService], which `flutter test` cannot resolve outside a
  /// built app bundle -- this seam lets UI-filtering tests exercise
  /// [selectableExportFiletypes] without going anywhere near that call.
  ///
  /// A factory (not a redirecting generative ctor) because it has a body:
  /// it builds exactly what the production ctor builds with every
  /// collaborator defaulted, then seeds the capability set.
  @visibleForTesting
  factory AppState.forTesting({
    required Set<ExportFiletype> runtimeCapabilities,
  }) {
    final state = AppState._(hydrate: false);
    state._runtimeExportCapabilities = runtimeCapabilities;
    return state;
  }

  /// The ONE construction path. [hydrate] is the only difference between
  /// production and [AppState.forTesting]: whether prefs hydration (and the
  /// capability probe it fires) runs.
  AppState._({
    PhotoLibraryScanner? scanner,
    PhotoStatusStore? statusStore,
    PhotoFileActions? fileActions,
    ImagePreloadController? preloadController,
    NativeImageLoad? imageLoader,
    DngFullDecoder? dngDecoder,
    DngOrientingFullDecoder? orientingDngDecoder,
    PhotoExportService? exportService,
    ExifBatchReader? exifReader,
    RetentionPolicy retention = const RetentionPolicy.floor(),
    int? physicalMemoryBytes,
    Duration exifDebounce = kSelectionExifDebounce,
    required bool hydrate,
  }) : _exifDebounce = exifDebounce,
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
          // Compressed residency v2 Task 4: the deferred full-size encode is
          // OPT-IN at the controller, so this is the argument that turns it on
          // in the shipped app. Dropping it would not fail anything visibly --
          // the slot would simply keep its temporary pixels forever -- so
          // `app_state_deferred_residency_test.dart` pins it.
          deferredEncodeDecoder: () => dngDecoder,
          orientingDngDecoder: orientingDngDecoder,
          // No sidebar decoder: USER RULING 2026-08-30 (contract D5) makes
          // the sidebar a CONSUMER of the shared q70 payload. The sized
          // 200px route it used to own is deleted -- measured NOT FASTER
          // than a full decode (ratio 0.916, payload-bench-report.md §4)
          // while costing a whole extra sensor decode outside the lane.
          retention: retention,
          physicalMemoryBytes: physicalMemoryBytes,
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
    if (hydrate) _initPrefs();
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

  /// What the deferred residency job inside the controller this AppState
  /// BUILT will actually get when it asks for a decoder (v2 Task 4).
  ///
  /// Reads through the controller's own supplier, so it cannot agree with a
  /// wiring that was never passed: if the `deferredEncodeDecoder` argument is
  /// dropped above, this is null and compressed residency is silently off.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  DngFullDecoder? get debugDeferredEncodeDecoder =>
      // ignore: invalid_use_of_visible_for_testing_member
      _preloadController.debugDeferredEncodeDecoder;

  /// One coherent reading of every byte ledger the preload controller owns,
  /// for the S3.0 memory-attribution capture (WP0.2).
  ///
  /// Delegates; holds no state of its own, so it cannot drift from the
  /// controller's ledgers. Works from BOTH constructors -- [AppState.forTesting]
  /// builds a real [ImagePreloadController] with real ledgers wired, so a
  /// capture self-test does not have to stand up a production AppState (real
  /// decoder, real folder) just to read one snapshot.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  MemoryLedgerSnapshot get debugMemoryLedgerSnapshot =>
      // ignore: invalid_use_of_visible_for_testing_member
      _preloadController.debugMemoryLedgerSnapshot;

  /// The retention slot ids the controller THIS `AppState` built is currently
  /// holding -- the per-slot DIMENSIONS capture the compressed-residency v2
  /// round could not produce (contract AC-1). Delegates rather than
  /// re-deriving, for the same non-drift reason as
  /// [debugMemoryLedgerSnapshot].
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  Set<String> get debugRetentionIds =>
      // ignore: invalid_use_of_visible_for_testing_member
      _preloadController.debugRetentionIds;

  /// The retained payload for [id] as the controller THIS `AppState` built
  /// reports it -- the DIMENSIONS-capture companion to [debugRetentionIds]:
  /// a slot id alone has no width/height/byte-length without reading back
  /// through the payload it points at.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  SourcePayload? debugPayloadFor(String? id) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _preloadController.payloadFor(id);

  final PhotoExportService _exportService;
  final ExifBatchReader _exifReader;
  late final RenameCoordinator _renameCoordinator;

  /// The policy actually in force. Read from the controller rather than the
  /// constructor argument, so an injected controller and this getter can
  /// never disagree.
  RetentionPolicy get retentionPolicy => _preloadController.retention;

  // Memory-pressure seam (WP4.4 / S3.4). Three pure delegates, no state and no
  // policy: the response policy lives in exactly one place,
  // `MemoryPressureResponder`, and the derived budget is owned by the
  // controller. Anything smarter here would be a second owner of one of those
  // two things.

  /// The payload budget the pipeline derives, ignoring any pressure override.
  int get derivedPayloadByteBudget =>
      _preloadController.derivedPayloadByteBudget;

  /// Overrides the payload budget; null restores the derived value.
  void setPayloadByteBudgetOverride(int? bytes) =>
      _preloadController.setPayloadByteBudgetOverride(bytes);

  /// Drops full-resolution pixels for items outside the full-resolution band.
  void dropBeyondBandTierTwoPixels() =>
      _preloadController.dropBeyondBandTierTwoPixels();

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
  final Duration _exifDebounce;

  // Settings: one immutable value. Every write goes through [_apply] except
  // hydration ([_initPrefs]), [resetAllSettings] and
  // [resolveExportCapabilities] -- see each for why.
  AppSettings _settings = AppSettings.defaults();

  /// The user's actual intent for [exportFiletype] -- the persisted pref
  /// name at hydration time, or the name last passed to [setExportFiletype].
  /// Runtime capability is not known yet when [_initPrefs] first computes
  /// the effective [exportFiletype] (see [resolveExportCapabilities]'s doc), so that
  /// first computation can downgrade to the default; without recording the
  /// ORIGINAL name separately, [resolveExportCapabilities] would renormalise
  /// from the already-downgraded effective `exportFiletype.name` once capability
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

  late final RetentionTier _autoRetentionTier;
  SharedPreferences? _prefs;

  // Per-folder, deliberately NOT persisted: every loadFolder re-detects, so
  // a new card always starts from the safe default.
  bool _recycleMode = false;

  // Latched for the process lifetime once a delete proves this machine has no
  // system-trash bridge. Deliberately NOT persisted, same as _recycleMode: a
  // fresh process re-discovers it on its first delete.
  bool _bridgeUnavailableLatched = false;

  // Bumps on every show so the view can restart its timer even when the
  // same text repeats (carried on [StatusEvent.seq]).
  int _statusSeq = 0;

  /// Fires once per [showStatus] call (see [StatusEvent]); [StatusLine]
  /// listens to this instead of the whole-app [notifyListeners] stream.
  final ValueNotifier<StatusEvent?> statusEvents = ValueNotifier(null);

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    final r = SettingsCodec.read(
      _prefs,
      selectableFiletypes: selectableExportFiletypes,
    );
    _settings = r.settings;
    _exportFiletypeIntentName = r.exportFiletypeIntentName;
    // Unconditional collaborator pushes, in the pre-refactor order.
    _preloadController.setDecodeLaneWidth(_settings.decodeLaneWidth);
    _exportService.jpegQuality = _settings.exportJpegQuality;
    _exportService.longEdge = _settings.exportLongEdge;
    _exportService.filetype = _settings.exportFiletype;
    // Fire-and-forget: resolving runtime capability requires a native call
    // that must not block prefs hydration/first paint. It re-normalises the
    // effective filetype and notifies once it completes (see
    // [resolveExportCapabilities]).
    unawaited(resolveExportCapabilities());
    _preloadController.setRetention(retentionPolicyForTier(retentionTier));

    // Guards the race documented on [resolveExportCapabilities]: this method
    // awaits SharedPreferences.getInstance() before reaching here, and a
    // short-lived AppState (e.g. a test) may already be disposed by the time
    // that resolves -- notifyListeners() on a disposed ChangeNotifier throws.
    if (_disposed) return;
    notifyListeners();
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
  bool get autoAdvance => _settings.autoAdvance;

  /// Drives `MaterialApp.themeMode` (main.dart). `system` resolves through the
  /// platform brightness, so this is the stored intent, not the rendering.
  ThemeMode get themeMode => _settings.themeMode;

  /// Selects which [LayoutTheme] the whole app arranges itself with, via
  /// `layoutThemeFor`. Replaced the `kActiveLayoutThemeId` constant.
  LayoutThemeId get layoutThemeId => _settings.layoutThemeId;
  bool get overwriteExisting => _settings.overwriteExisting;

  bool get recycleMode => _recycleMode;

  int get decodeLaneWidth => _settings.decodeLaneWidth;

  /// The largest width the user may set. Fixed on every platform (AD-044).
  int get maxDecodeLaneWidth => kMaxDecodeLaneWidth;

  /// R4 item 1 / ruling r-6. This machine's ADVISORY recommended decode widths
  /// for the 24 MP / 61 MP / 108 MP sensor-resolution classes, in that order,
  /// or null when the native layer has not reported them yet (no decode worker
  /// has booted) or cannot (the pinned dylib predates the query).
  ///
  /// FOR DISPLAY ONLY. [setDecodeLaneWidth] does not consult this, and no code
  /// path may clamp the user's setting against it: the user's value reaches
  /// both the Dart decode pool and the native slot pool unmodified. The
  /// settings dialog shows these numbers so the choice is informed, not
  /// constrained.
  List<int>? get decodeWidthRecommendations =>
      halcyonDecodeWidthRecommendations();

  int get exportJpegQuality => _settings.exportJpegQuality;

  int get exportLongEdge => _settings.exportLongEdge;

  ExportFiletype get exportFiletype => _settings.exportFiletype;

  /// The export filetypes the native library reported as available at runtime
  /// (ruling Q4), in enum order; just the default when none were. The
  /// settings panel's segmented control and [SettingsCodec.normaliseFiletype] both
  /// read this.
  List<ExportFiletype> get selectableExportFiletypes {
    final caps = _runtimeExportCapabilities;
    if (caps.isEmpty) return const [kDefaultExportFiletype];
    return ExportFiletype.values.where(caps.contains).toList();
  }

  /// Probes the native library once. Safe to call before the dylib exists:
  /// every failure degrades to "only the default is offered" rather than
  /// throwing, matching the never-throws contract the probe layer already
  /// has.
  Future<void> resolveExportCapabilities({CeyxEncodeService? service}) async {
    final svc = service ?? CeyxEncodeService();
    final found = <ExportFiletype>{};
    for (final ft in ExportFiletype.values) {
      if (await svc.supports(ft.format)) found.add(ft);
    }
    // The probe above is fired-and-forgotten from `_initPrefs`/the app-startup
    // caller; by the time every `supports()` call has resolved this AppState
    // may already have been disposed (a short-lived test, or a view torn
    // down mid-startup) -- `notifyListeners()` on a disposed ChangeNotifier
    // throws, so this must bail out instead of touching state or listeners.
    if (_disposed) return;
    _runtimeExportCapabilities = found.isEmpty ? const {} : found;
    // THE one settings write that bypasses [_apply], deliberately: a
    // capability-driven re-normalisation is never persisted (the stored
    // intent must survive a run on a build that cannot encode it).
    // Re-normalise from the ORIGINAL intent name, not the effective name:
    // hydration may already have downgraded the effective value before
    // capability was known, and renormalising from that would permanently
    // discard the user's real preference.
    final effective = SettingsCodec.normaliseFiletype(
      _exportFiletypeIntentName ?? _settings.exportFiletype.name,
      selectableExportFiletypes,
    );
    _settings = _settings.copyWith(exportFiletype: effective);
    _exportService.filetype = effective;
    notifyListeners();
  }

  /// The tier this machine derives from its own RAM, i.e. what "Auto" means.
  RetentionTier get autoRetentionTier => _autoRetentionTier;
  RetentionTier get retentionTier =>
      _settings.retentionTierOverride ?? _autoRetentionTier;
  bool get isRetentionTierOverridden => _settings.retentionTierOverride != null;
  ShortcutBindings get shortcutBindings => _settings.shortcuts;

  void showStatus(StatusMessage message) {
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

  /// PHASE 5: [id]'s own payload readiness, for a widget that wants to repaint
  /// when THAT item lands rather than when anything in the app changes.
  ///
  /// A listenable, never bytes: the tier-1/tier-2 provider factories stay the
  /// controller's (AD-028), so a view still reads its pixels through the
  /// getters above -- this only tells it WHEN to.
  ///
  /// Safe after [dispose]: the controller disposes its notifiers, and a
  /// disposed `PayloadStateNotifier` ignores listener add/remove instead of
  /// asserting -- the same `_disposed` discipline as the landing callback
  /// handed to the controller in [_preloadImages].
  ValueListenable<PayloadState> payloadStateFor(String id) =>
      _preloadController.stateFor(id);

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
      _recycleMode = _bridgeUnavailableLatched ||
          _items.any((item) => item.files.length > 1);
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
        if (_settings.autoAdvance) {
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

  /// THE single settings write path: persist the changed fields, push the
  /// changed fields to the collaborators that hold their own copies, notify
  /// once (always -- every setter notified unconditionally before this).
  void _apply(AppSettings next) {
    final old = _settings;
    _settings = next;
    SettingsCodec.persistDiff(_prefs, old, next);
    if (old.decodeLaneWidth != next.decodeLaneWidth) {
      _preloadController.setDecodeLaneWidth(next.decodeLaneWidth);
    }
    if (old.retentionTierOverride != next.retentionTierOverride) {
      _preloadController.setRetention(retentionPolicyForTier(
          next.retentionTierOverride ?? _autoRetentionTier));
    }
    if (old.exportJpegQuality != next.exportJpegQuality) {
      _exportService.jpegQuality = next.exportJpegQuality;
    }
    if (old.exportLongEdge != next.exportLongEdge) {
      _exportService.longEdge = next.exportLongEdge;
    }
    if (old.exportFiletype != next.exportFiletype) {
      _exportService.filetype = next.exportFiletype;
    }
    notifyListeners();
  }

  void setAutoAdvance(bool value) =>
      _apply(_settings.copyWith(autoAdvance: value));

  void setOverwriteExisting(bool value) =>
      _apply(_settings.copyWith(overwriteExisting: value));

  void setDecodeLaneWidth(int value) => _apply(_settings.copyWith(
      decodeLaneWidth: SettingsCodec.clampLaneWidth(value)));

  void setExportJpegQuality(int quality) => _apply(_settings.copyWith(
      exportJpegQuality: SettingsCodec.normaliseQuality(quality)));

  void setExportLongEdge(int longEdge) => _apply(_settings.copyWith(
      exportLongEdge: SettingsCodec.normaliseLongEdge(longEdge)));

  void setExportFiletype(ExportFiletype filetype) {
    // Record the user's real intent BEFORE gating: a later
    // resolveExportCapabilities() re-normalises from this name, so an
    // explicit pick a capability probe hasn't caught up with yet is not
    // lost the way a persisted-but-unresolved pref would be.
    _exportFiletypeIntentName = filetype.name;
    final effective = selectableExportFiletypes.contains(filetype)
        ? filetype
        : kDefaultExportFiletype;
    // An explicit pick always persists its effective name, even when the
    // effective value is unchanged: the stored name may be a pending intent
    // (e.g. 'heif' on a build that cannot encode it) that this pick must
    // overwrite. [_apply] persists only changed fields, so write it here.
    // Pinned by TC-452 / TC-476 (app_state_settings_test.dart).
    if (effective == _settings.exportFiletype) {
      _prefs?.setString(SettingsCodec.kExportFiletype, effective.name);
    }
    _apply(_settings.copyWith(exportFiletype: effective));
  }

  void setThemeMode(ThemeMode mode) =>
      _apply(_settings.copyWith(themeMode: mode));

  void setLayoutThemeId(LayoutThemeId id) =>
      _apply(_settings.copyWith(layoutThemeId: id));

  void setRetentionTier(RetentionTier tier) =>
      _apply(_settings.copyWith(retentionTierOverride: tier));

  void resetRetentionTierToAuto() =>
      _apply(_settings.copyWith(retentionTierOverride: null));

  // Conflicts are ACCEPTED here by design: the panel warns and dispatch has
  // a deterministic winner (ShortcutBindings.actionFor). Blocking would make
  // the mockup's warning state unreachable.
  void setShortcutBinding(ShortcutAction action, LogicalKeyboardKey key) =>
      _apply(_settings.copyWith(
          shortcuts: _settings.shortcuts.withBinding(action, key)));

  void resetShortcutBinding(ShortcutAction action) => _apply(
      _settings.copyWith(shortcuts: _settings.shortcuts.withDefault(action)));

  void resetAllShortcutBindings() =>
      _apply(_settings.copyWith(shortcuts: ShortcutBindings.defaults()));

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
    _settings = AppSettings.defaults();
    _exportFiletypeIntentName = null;

    // The collaborators hold their own copies; resetting the field without
    // pushing it through is how a "reset" leaves the pipeline on the old
    // value while the panel claims otherwise. Unconditional, as before.
    _preloadController.setDecodeLaneWidth(_settings.decodeLaneWidth);
    _preloadController.setRetention(retentionPolicyForTier(retentionTier));
    _exportService.jpegQuality = _settings.exportJpegQuality;
    _exportService.longEdge = _settings.exportLongEdge;
    _exportService.filetype = _settings.exportFiletype;

    notifyListeners();
    // Awaited last: the in-memory reset and the notify must not wait on disk,
    // but the future is returned so a caller (and a test) can await the store
    // actually being empty.
    await _prefs?.clear();
  }

  /// The settings dialog's revert snapshot. [AppSettings] is immutable, so
  /// the live value IS the snapshot -- no copy.
  AppSettings settingsSnapshot() => _settings;

  /// Puts every panel-changeable field back, prefs included, through the one
  /// write path, so no path can revert in-memory state while leaving the
  /// persisted value changed. Notifies once (sanctioned change, AR-3).
  void restoreSettings(AppSettings snapshot) {
    // Same intent rule as before the refactor: the revert re-records the
    // intent only when the effective filetype actually changes back.
    if (snapshot.exportFiletype != _settings.exportFiletype) {
      _exportFiletypeIntentName = snapshot.exportFiletype.name;
    }
    _apply(snapshot);
  }

  // Preload sliding window: before/after counts come from the active
  // RetentionPolicy (e.g. 3/5 for the conservative tier; wider for others),
  // not a fixed 3/5 for every tier -- see RetentionPolicy in
  // retention_policy.dart.
  Future<void> _preloadImages() async {
    final selectedId = _selectedItemID;
    if (selectedId == null) return;

    // No `notifyLoaded`: since P1 a landing wakes exactly the item that
    // landed, through `payloadStateFor(id)` -> the viewer's
    // `ValueListenableBuilder` (see `photo_viewport.dart`). The app-wide
    // callback this used to pass was also what MASKED the two payload-state
    // races fixed earlier in P1 (a stale/orphaned per-item notifier still got
    // a repaint because everything repainted), which is why its removal is
    // ordered strictly after those fixes (see
    // docs/logs/2026-09-06/p3-plan-P1.md Task 5).
    await _preloadController.preloadImages(
      items: _items,
      selectedItemId: selectedId,
    );
  }

  // [startIdx]..[endIdx] is the sidebar's VISIBLE row range; the controller
  // adds its own prefetch margin around it (see thumbnailPrefetchMargin).
  Future<void> preloadThumbnails(int startIdx, int endIdx) async {
    // No `notifyLoaded`: since Phase 5 commit B a landed tile wakes its own
    // row's listener (see `SidebarThumbnailController._onTileLanded`), so
    // there is nothing strip-wide left to notify.
    await _preloadController.preloadThumbnails(
      items: _items,
      startIdx: startIdx,
      endIdx: endIdx,
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
        overwriteExisting: _settings.overwriteExisting,
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
    final out = await _fileActions.deleteBatch(
      _items,
      dir,
      recycleMode: _recycleMode,
    );
    // Process-lifetime UI policy (read by loadFolder's recycle heuristic):
    // the service reports the fact, the provider owns the latch.
    if (out.bridgeUnavailable) _bridgeUnavailableLatched = true;
    if (dir != null) {
      await _reloadPreservingSelection(dir);
    }
    return out.result;
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
    _exifDebounceTimer = Timer(_exifDebounce, () {
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
    // Guards the same race documented on `_initPrefs` and
    // `resolveExportCapabilities`: this method awaits the EXIF reader,
    // and a short-lived AppState (a test, or a view torn down mid-read) may
    // already be disposed by the time that resolves -- `notifyListeners()` on
    // a disposed ChangeNotifier throws. `dispose()` cancels the debounce
    // timer, but cancelling does nothing once the timer has ALREADY fired and
    // this method is suspended on the await above, and `dispose()` does not
    // bump `_exifGeneration`, so the generation check above does not cover it
    // either. TC-1058; this is what made TC-542 flaky under full-suite load.
    if (_disposed) return;
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
    super.dispose();
  }
}
