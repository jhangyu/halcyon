# Bitmap decoders phase 2 (HEIC) — acceptance gate

Artifact regenerated once to fix two template self-collisions (prose token matching its own acceptance grep; TC-318 evidence living in the native build log): judging semantics unchanged, raw build/test logs verbatim and unmodified.

Pre-registered pass rule (fixed before this run, per the plan's Task 9):
  (a) flutter analyze ends with 'No issues found!' and RC=0
  (b) flutter test -j 1 contains 'All tests passed!' and RC=0
  (c) this artifact contains all of TC-314 .. TC-320
  (d) the macOS build exits RC=0 with an S4 [CFA COLOR] PASS line and
      no colour-gate opt-out flag appears in any command
  (e) the H1 gate line reads [HEIF COLOR] ... PASS
  (f) otool -L shows both @rpath HEIF dependencies and nm -gU finds
      heif_probe, heif_decode_rgba and heif_release
Any other outcome is a REPORTED FAILURE, not a re-run with different arguments.

commit: 52697cb322d0492453e3ab86b460c07aacc0641d
ceyx commit: 25b06f44b82cfe15123ccfc078124115e35d2867

## $ flutter analyze
```
Analyzing Halcyon-decoders...                                   
No issues found! (ran in 0.8s)
RC=0
```

## $ flutter test -j 1
```
00:00 +0: loading /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_open_with_test.dart
00:00 +0: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_open_with_test.dart: AppState.openPhotoAtPath TC-160 keeps the loaded folder when the file does not exist
00:00 +1: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_open_with_test.dart: AppState.openPhotoAtPath TC-161 keeps the loaded folder when the parent directory is missing
00:00 +2: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_open_with_test.dart: AppState.openPhotoAtPath TC-162 still opens a real file and selects it
00:00 +3: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_open_with_test.dart: AppState.openPhotoAtPath TC-163 ignores unsupported extensions
00:00 +4: loading /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart
00:00 +4: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.loadFolder scans supported files, ignores hidden files, and groups by photo id
00:00 +5: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.loadFolder warns on the status line when the folder is read-only
00:00 +6: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.loadFolder restores saved statuses and last viewed id from JSON
00:00 +7: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.loadFolder scans RW2 files into photo groups
00:00 +8: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.loadFolder groups CR2/NEF/ORF raw files with their JPG sibling
00:00 +9: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking auto-advance moves to the next photo after applying a new status
00:00 +10: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking uses semantic image request purposes for preview and sidebar thumbnail loading
00:00 +11: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking toggling a status off does not auto-advance even when auto-advance is on
00:00 +12: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking nextPhoto and previousPhoto move selection within bounds
00:00 +13: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking TC-222 currentItem returns null for a selection that is gone
00:00 +14: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking TC-223 currentItem does not throw on an empty item list
00:00 +15: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking TC-221 a failing copy surfaces a status message
processStarred failure: IMG_0001.jpg: FileSystemException: Cannot copy file to '/var/folders/pm/m43m8lxj3dx50nsw5ggjw_580000gn/T/halcyon_ps221_dest_qpZQKn/IMG_0001.jpg', path = '/var/folders/pm/m43m8lxj3dx50nsw5ggjw_580000gn/T/halcyon_ps221_src_1fCNQD/IMG_0001.jpg' (OS Error: Is a directory, errno = 21)
00:00 +16: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking TC-224 a scan failure surfaces a status message
Error loading directory: FileSystemException: unreadable, path = ''
00:00 +17: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState selection and marking TC-225 readMetadataFor chunks once and reports progress
00:00 +18: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.openPhotoAtPath loads the containing folder and selects the given file
00:00 +19: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.openPhotoAtPath ignores unsupported files instead of clearing the folder
00:00 +20: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState recycle mode defaults on when a folder has same-name sibling groups
00:00 +21: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState recycle mode defaults off when every photo has a single extension
00:00 +22: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState recycle mode toggles both ways and notifies listeners
00:00 +23: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState recycle mode recycle mode moves files to .trash instead of the system trash
00:00 +24: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState recycle mode direct mode still routes through the system trash
00:01 +25: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: AppState.processStarred selection restore TC-248 keeps the selected photo, falling back to its index
00:01 +26: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: renameByExif TC-049 renames files and moves the star to the new id
00:01 +27: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: renameByExif TC-050 undo restores the original names and the star
00:01 +28: /Users/jhangyu/project/Halcyon-decoders/test/providers/app_state_test.dart: renameByExif TC-051 a custom rule is saved; a preset clears it
00:01 +29: loading /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart
00:01 +29: /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart: TC-024 default template renders zero-padded date and time
00:01 +30: /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart: TC-025 {seq} defaults to one digit, {seq:3} zero-pads to three
00:01 +31: /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart: TC-026 missing capture date falls back to file mtime
00:01 +32: /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart: TC-027 non-date variables render, missing ones render empty
00:01 +33: /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart: TC-028 path-hostile characters are replaced, edges trimmed
00:01 +34: /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart: TC-029 unknown variable and empty result are reported as errors
00:01 +35: /Users/jhangyu/project/Halcyon-decoders/test/models/rename_rule_test.dart: TC-030 every preset is a valid template and the default is first
00:01 +36: loading /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart
00:01 +36: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: SupportedPhotoFormats.decodableExtensions derives exactly from kSupportedDecodeExtensions, dotted form
00:01 +37: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: D2 browse-only extensions (.cr2, .iiq, .mrw) are NOT in decodableExtensions
00:01 +38: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: D2 browse-only extensions (.cr2, .iiq, .mrw) ARE in rawExtensions and supportedExtensions
00:01 +39: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: isDecodablePath true for an engine-decodable extension
00:01 +40: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: isDecodablePath false for a D2 browse-only extension
00:01 +41: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: isDecodablePath false for an unsupported extension
00:01 +42: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: AC1 — folder scan surfaces a file of every derived-list extension over a fake directory listing, every decodable+browse-only ext is picked up
00:01 +43: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: rawExtensions / supportedExtensions composition rawExtensions == decodableExtensions union browseOnlyRawExtensions
00:01 +44: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: rawExtensions / supportedExtensions composition supportedExtensions includes engine bitstreams, bitmap-decode and all raw extensions
00:01 +45: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: phase-1 bitmap formats TC-302: .webp/.tif/.tiff are supported, .xyz is not
00:01 +46: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: phase-1 bitmap formats TC-302: .webp is an engine bitstream, .tif/.tiff are bitmap-decode
00:01 +47: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: phase-1 bitmap formats TC-302: hasFullDecodeRoute covers RAW and TIFF but not D2/bitstream
00:01 +48: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: phase-1 bitmap formats TC-304: bestFileToLoad prefers .jpg over .webp, .webp over .dng
00:01 +49: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: phase-2 HEIC formats TC-302: .heic/.heif are bitmap-decode, not engine bitstreams
00:01 +50: /Users/jhangyu/project/Halcyon-decoders/test/models/supported_photo_formats_test.dart: phase-2 HEIC formats TC-302: a HEIC sibling does not outrank a JPEG sibling
00:01 +51: loading /Users/jhangyu/project/Halcyon-decoders/test/models/photo_item_test.dart
00:02 +51: /Users/jhangyu/project/Halcyon-decoders/test/models/photo_item_test.dart: PhotoItem.bestFileToLoad prefers JPG over RAW files in the same group
00:02 +52: /Users/jhangyu/project/Halcyon-decoders/test/models/photo_item_test.dart: PhotoItem.bestFileToLoad falls back to the first RAW file when no preview format exists
00:02 +53: /Users/jhangyu/project/Halcyon-decoders/test/models/photo_item_test.dart: SupportedPhotoFormats central registry includes RW2 and excludes unsupported files
00:02 +54: /Users/jhangyu/project/Halcyon-decoders/test/models/photo_item_test.dart: SupportedPhotoFormats HEIC is scanned in phase 2, and never outranks a cheap engine sibling
00:02 +55: loading /Users/jhangyu/project/Halcyon-decoders/test/main_test.dart
00:02 +55: /Users/jhangyu/project/Halcyon-decoders/test/main_test.dart: configureImageCache raises ImageCache.maximumSizeBytes to 768 MiB (default 100MB only fits ~1 full-frame decode)
00:02 +56: /Users/jhangyu/project/Halcyon-decoders/test/main_test.dart: main screen accepts file drops through DropTarget
00:03 +57: /Users/jhangyu/project/Halcyon-decoders/test/main_test.dart: R key toggles recycle mode
00:03 +58: /Users/jhangyu/project/Halcyon-decoders/test/main_test.dart: HalcyonApp renders empty-folder prompt
00:03 +59: /Users/jhangyu/project/Halcyon-decoders/test/main_test.dart: DropTarget is disabled while a dialog route is on top
00:03 +60: loading /Users/jhangyu/project/Halcyon-decoders/test/perf/perf_log_build_stamp_test.dart
00:03 +60: /Users/jhangyu/project/Halcyon-decoders/test/perf/perf_log_build_stamp_test.dart: P-2b kHalcyonBuildCommit reflects HALCYON_BUILD_COMMIT at compile time
00:03 +61: loading /Users/jhangyu/project/Halcyon-decoders/test/views/photo_action_bar_test.dart
00:04 +61: /Users/jhangyu/project/Halcyon-decoders/test/views/photo_action_bar_test.dart: direct mode shows the trash can icons
00:04 +62: /Users/jhangyu/project/Halcyon-decoders/test/views/photo_action_bar_test.dart: recycle mode shows the restore-from-trash icons
00:04 +63: loading /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart
00:05 +63: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: trashed status icon follows the mode
00:05 +64: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: invoking onSelected with the shared constant reaches the export path
00:05 +65: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: TC-055 onSelected with the shared constant opens the dialog
00:05 +66: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: sidebar sweep routes sidebarThumbnail requests through the Dart producer
00:06 +67: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: sidebar RAW-decode fallback: decodable PNG for a bare-CFA DNG, maxDim 200 requested
00:06 +68: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: sidebar RAW-decode fallback: decoder throwing is a permanent miss, no crash, no retry signal
00:06 +69: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: sidebar RAW-decode fallback: a non-RAW item never reaches the decoder
00:06 +70: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_test.dart: TC-226 the overflow menu exposes exactly the five actions
00:06 +71: loading /Users/jhangyu/project/Halcyon-decoders/test/views/main_detail_view_test.dart
00:07 +71: /Users/jhangyu/project/Halcyon-decoders/test/views/main_detail_view_test.dart: TC-230 the detail view spins with no bytes and no provider
00:07 +72: loading /Users/jhangyu/project/Halcyon-decoders/test/views/theme_tokens_test.dart
00:07 +72: /Users/jhangyu/project/Halcyon-decoders/test/views/theme_tokens_test.dart: TC-229 HalcyonTokens.of falls back to dark
00:08 +73: /Users/jhangyu/project/Halcyon-decoders/test/views/theme_tokens_test.dart: TC-229b lerp returns a HalcyonTokens, not null
00:08 +74: loading /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_thumbnail_decode_cap_test.dart
00:08 +74: /Users/jhangyu/project/Halcyon-decoders/test/views/sidebar_view_thumbnail_decode_cap_test.dart: AC2/AC3: sidebar thumbnail decode is capped at 32*devicePixelRatio on the longest edge and preserves source aspect ratio within 1%
00:09 +75: loading /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart
00:09 +75: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: ordinary zoom request a plain zoom-in from identity requests an animation
00:09 +76: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: ordinary zoom request a plain zoom-out from a zoomed-in state requests an animation
00:09 +77: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: upper bound zooming in repeatedly clamps at exactly 5.0x
00:09 +78: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: upper bound a step at the 5.0x ceiling produces no further zoom request
00:09 +79: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: lower bound reset a target scale <= 1.05 snaps back to identity, not to 1.0x-ish
00:09 +80: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: lower bound reset a scale still above 1.05 after zoom-out is NOT reset to identity
00:09 +81: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: focus selection uses pointerPosition when the cursor is over the viewer
00:09 +82: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: focus selection falls back to lastKnownCenter when the cursor has left
00:09 +83: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: focus selection a later layout centre is used once the pointer exits
00:09 +84: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: notification contract a zoom request notifies listeners exactly once
00:09 +85: /Users/jhangyu/project/Halcyon-decoders/test/views/zoom_controller_test.dart: notification contract writing lastKnownCenter or pointerPosition never notifies
00:09 +86: loading /Users/jhangyu/project/Halcyon-decoders/test/views/rename_dialog_test.dart
00:10 +86: /Users/jhangyu/project/Halcyon-decoders/test/views/rename_dialog_test.dart: TC-052 every preset and every variable chip is rendered
00:10 +87: /Users/jhangyu/project/Halcyon-decoders/test/views/rename_dialog_test.dart: TC-053 an invalid rule disables Rename and shows the reason
00:10 +88: /Users/jhangyu/project/Halcyon-decoders/test/views/rename_dialog_test.dart: TC-054 tapping a chip appends its token to the rule
00:10 +89: loading /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart
00:11 +89: /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart: holds for 2.5s, fades over 0.5s, gone at 3.0s
00:11 +90: /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart: a second message restarts the timer
00:11 +91: /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart: emphasisSpans colours only the starred runs
00:11 +92: /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart: TC-056 an action message renders a button that fires once
00:11 +93: /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart: reveal builds the right command per OS and surfaces failure
00:11 +94: /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart: reveal returns null on a successful (exit 0) process run
00:11 +95: /Users/jhangyu/project/Halcyon-decoders/test/views/status_line_test.dart: reveal surfaces a ProcessException (binary missing / spawn failure)
00:11 +96: loading /Users/jhangyu/project/Halcyon-decoders/test/services/platform/open_with_channel_test.dart
00:12 +96: /Users/jhangyu/project/Halcyon-decoders/test/services/platform/open_with_channel_test.dart: a pushed openFile call is delivered to the listener
00:12 +97: /Users/jhangyu/project/Halcyon-decoders/test/services/platform/open_with_channel_test.dart: an empty path is ignored
00:12 +98: /Users/jhangyu/project/Halcyon-decoders/test/services/platform/open_with_channel_test.dart: an unrecognised method is ignored
00:12 +99: loading /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart
00:12 +99: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.deleteTrashed moves trashed files and sidecars through the trash service
00:12 +100: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.deleteTrashed keeps the source file when trash service fails
00:12 +101: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.deleteTrashed TC-207 deleteTrashed continues past a failing trash call
00:12 +102: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred copy mode copies starred items to the destination, leaves the source untouched, skips unstarred items
00:12 +103: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred move mode moves starred items to the destination, removes the source, leaves unstarred untouched
00:12 +104: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred move mode processes every sibling file in a RAW+JPG group
00:12 +105: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred overwriteExisting=false skips a starred file whose destination already exists, source is left alone
00:12 +106: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred overwriteExisting=true replaces an existing destination file
00:12 +107: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred copy mode discards a preexisting destination AppleDouble sidecar and keeps the source sidecar
00:12 +108: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred move mode discards the source AppleDouble sidecar instead of moving it
00:12 +109: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred does nothing when the destination folder does not exist
00:12 +110: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.processStarred TC-206 processStarred continues past a failing file
00:12 +111: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.recycleTrashed moves every sibling file and sidecar into .trash
00:12 +112: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.recycleTrashed suffixes collisions instead of overwriting
00:12 +113: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: PhotoFileActions.recycleTrashed records per-file failures and keeps processing the rest
00:12 +114: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_file_actions_test.dart: TC-212 sidecarPathFor prefixes the basename only
00:12 +115: loading /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart
00:12 +115: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: only starred items are exported; unmarked/trashed are not
00:12 +116: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: an item with .dng + .jpg siblings produces exactly one output file, from the JPEG source
00:12 +117: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: an existing destination file is overwritten
00:12 +118: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: a fetch that returns null or throws lands in failures and the remaining items still export
00:12 +119: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: onProgress is called once per item with a monotonically increasing done and the correct total
00:12 +120: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: a destination that does not exist returns an empty outcome without throwing
00:12 +121: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: default fetch (no fetchBytes injected): pure-Dart export pipeline a preview-bearing DNG exports a JPEG with long edge <= 2048, no channel call
00:14 +122: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: default fetch (no fetchBytes injected): pure-Dart export pipeline a no-preview DNG with an injected decoder exports via the raw-decode branch, no channel call
00:14 +123: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: default fetch (no fetchBytes injected): pure-Dart export pipeline a no-preview DNG with NO decoder injected fails the item, no crash, no channel call
00:14 +124: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: exportBytesFor: source EXIF carry-over (P3 review P-14 ruling) export of a DNG with source Make/Model/DateTimeOriginal EXIF carries those tags into the output JPEG, with Orientation forced to 1
00:15 +125: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 1: identity
00:15 +126: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 2: flip horizontal
00:15 +127: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 3: rotate 180
00:15 +128: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 4: flip vertical (no-op on a 1-row image, colours unchanged)
00:15 +129: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 5: transpose (rotate 90 + flip horizontal)
00:15 +130: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 6: rotate 90 CW
00:15 +131: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 7: transverse (rotate 270 + flip horizontal)
00:15 +132: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: bakeExifOnDecoded: all 8 EXIF orientation values orientation 8: rotate 270 CW
00:15 +133: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: A7 offset-view export regression TC-214 an offset-view RGBA buffer exports the same pixels
00:15 +134: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: A7 offset-view export regression TC-215 a length/dimension mismatch returns null, not garbage
00:15 +135: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: shared orientation table parity TC-216 bakeExifOnDecoded agrees with the shared table for 1..8
00:15 +136: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_export_service_test.dart: TC-312: exporting a TIFF produces a JPEG with long edge <= 2048 and Orientation == 1
00:16 +137: loading /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart
00:16 +137: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart: TC-041 a custom rule survives a round trip
00:16 +138: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart: TC-042 saveStatuses preserves _last_viewed_id and _rename_rule
00:16 +139: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart: TC-043 applySavedStatuses does not treat _rename_rule as a stale key
00:16 +140: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart: TC-044 remapKeys moves marks and the last-viewed id to new ids
00:16 +141: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart: TC-208 a corrupt status file loads as empty instead of throwing
Halcyon: unreadable .halcyon_status.json (FormatException: Unterminated string (at character 13)
{"A": "starr
            ^
); ignoring it
00:16 +142: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart: TC-209 corrupt JSON degrades on every read entry point
00:16 +143: /Users/jhangyu/project/Halcyon-decoders/test/services/library/photo_status_store_test.dart: TC-210 concurrent saves do not lose each other's keys
00:16 +144: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_scheduler_test.dart
00:17 +144: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_scheduler_test.dart: TC-239 the debounce is a cancel-and-reschedule: only the FINAL navigation position ever gets a tier-2 sweep
00:17 +145: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_scheduler_test.dart: TC-240 the tier-2 queue is sequential: exactly ONE load is in flight at a time, released in near-to-far order
00:17 +146: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_scheduler_test.dart: TC-241 the window re-check is INSIDE the queued body: an item the user has navigated away from is dropped instead of loaded
00:17 +147: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_scheduler_test.dart: TC-242 a swept window publishes its encoded payloads to the registry, and the next sweep evicts the ids that left the window
00:17 +148: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart
00:17 +148: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: sample directory exists with at least one DNG
00:17 +149: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-19-37-38.dng: extracts a decodable SOI/EOI-bounded JPEG
00:17 +150: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-20-53-24.dng: extracts a decodable SOI/EOI-bounded JPEG
00:17 +151: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-20-53-31.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +152: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-20-57-15.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +153: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-20-57-23-2.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +154: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-20-57-23.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +155: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-20-57-26.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +156: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-20-57-28.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +157: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-21-53-33.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +158: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-21-53-41.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +159: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-21-53-42.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +160: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-02-15-21-53-43.dng: extracts a decodable SOI/EOI-bounded JPEG
00:18 +161: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview 2026-08-07-17-52-54.dng: extracts a decodable SOI/EOI-bounded JPEG
00:19 +162: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: IMG_20251112_092839.dng (no qualifying embedded preview) returns null, not a crash
00:19 +163: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: orientation tag: sample with EXIF orientation 6 is read and injected
00:19 +164: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws empty bytes
00:19 +165: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws too short to contain a TIFF header
00:19 +166: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws wrong byte-order marker (not II/MM)
00:19 +167: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws valid byte-order marker but garbage magic/IFD offset
00:19 +168: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws a real DNG truncated mid-file (IFD offsets now point past EOF)
00:19 +169: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws a plain JPEG (non-DNG) file is rejected without throwing
00:19 +170: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws extractFullSizeEmbeddedJpegFromFile on a nonexistent path returns null
00:19 +171: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: malformed/truncated/non-DNG input degrades to null, never throws readDngOrientation degrades to 1 for malformed input
00:19 +172: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling E: orientation is clamped to the EXIF-legal range 1..8 raw orientation 0 is reported as 1
00:19 +173: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling E: orientation is clamped to the EXIF-legal range 1..8 raw orientation 1 is reported as 1
00:19 +174: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling E: orientation is clamped to the EXIF-legal range 1..8 raw orientation 8 is reported as 8
00:19 +175: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling E: orientation is clamped to the EXIF-legal range 1..8 raw orientation 9 is reported as 1
00:19 +176: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling E: orientation is clamped to the EXIF-legal range 1..8 the null row: undetermined stays 1 where the contract folds it, and stays null where the contract preserves it
00:19 +177: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling G-2: minLongEdge rejects an undersized selected candidate longEdge: null — rejected with minLongEdge, returned without
00:19 +178: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling G-2: minLongEdge rejects an undersized selected candidate longEdge: 200 — same pair, proving it applies in both selection modes and not just the full-size one
00:19 +179: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling G-2: minLongEdge rejects an undersized selected candidate minLongEdge rejects rather than re-selects: a container that HAS a qualifying candidate still returns the largest, not the smallest one clearing the bar
00:19 +180: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: M7 ruling G-2: minLongEdge rejects an undersized selected candidate the default is null, i.e. every existing caller is unchanged
00:19 +181: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) full-size request selects the JpgFromRaw2 (0x0127) blob
00:20 +182: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) sidebar request (longEdge 200) picks the smaller 0x002E blob
00:20 +183: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) the same container with version word 42 keeps the old behaviour: vendor tags are not honoured outside the Panasonic flavour
00:21 +184: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) an unknown version word is still rejected: the gate opened for 85, not for everything
00:22 +185: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) orientation is read from IFD0 and injected into the blob
00:22 +186: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) readImageDimensions falls back to the vendor extent tags
00:23 +187: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) probeContent measures the largest blob without reading a strip
00:23 +188: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) AC4 — the two "no preview" states stay distinguishable declares no preview tag at all -> miss, malformed FALSE (routes to a real RAW decode)
00:23 +189: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) AC4 — the two "no preview" states stay distinguishable declares a preview whose every blob is unreadable -> malformed TRUE
00:23 +190: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) AC4 — the two "no preview" states stay distinguishable an intact but undersized blob is a deliberate miss, not damage
00:23 +191: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) bounds checking is not weakened blob offset points past EOF
00:23 +192: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) bounds checking is not weakened blob byte count runs off the end of the file
00:24 +193: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) bounds checking is not weakened blob is in range but carries no SOI -> declared and broken
00:24 +194: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) bounds checking is not weakened blob has an SOI but no reachable frame header -> dropped as unmeasurable, NOT reported as damage
00:24 +195: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) bounds checking is not weakened a header claiming version 85 whose IFD0 offset is past EOF walks to null, malformed FALSE (AD-022 third case)
00:24 +196: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) bounds checking is not weakened a self-referential IFD0 offset terminates
00:24 +197: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_test.dart: Panasonic container (TIFF version word 85) bounds checking is not weakened a Panasonic-magic file truncated to the bare header does not throw
00:24 +198: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_no_method_channel_test.dart
00:24 +198: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_no_method_channel_test.dart: AC4: preview DNG produces bytes with ZERO channel-seam calls
00:24 +199: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_no_method_channel_test.dart: AC5: with the channel throwing MissingPluginException, cheap AND no-preview DNGs still behave
00:24 +200: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart
00:25 +200: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: AC3: NativeImageResult has exactly three variants and the D3 platform state is a failure CODE, not a fourth variant
00:25 +201: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: jpeg returns its exact bytes without decoding
00:25 +202: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: preview-bearing DNGs return exactly the extractor bytes
00:26 +203: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: no-preview DNGs yield NeedsRawDecode with the walked orientation
00:26 +204: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: sidebar purpose never returns the raw-decode signal
00:26 +205: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: missing file is a failure, not a throw
00:26 +206: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: browse-only RAW (.cr2): embedded preview is served, no-preview is an explicit unsupported state (never the raw-decode signal)
00:26 +207: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: engine-decodable non-DNG RAW (.arw): embedded preview is served, no-preview now routes to RAW decode
00:26 +208: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: the sidebar still never returns the raw-decode signal for an engine-decodable non-DNG RAW
00:27 +209: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: F-20: a header claiming a 40000x40000 decode is refused, never handed to a raw decode
00:27 +210: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: F-20: the guard does not fire on real, ordinary-sized samples
00:27 +211: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: G-2 undersized-candidate rule (a) preview on an undersized .dng enters RAW decode instead of returning the undersized bytes
00:27 +212: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: G-2 undersized-candidate rule (b) the sidebar stays lenient (P-11/P-13)
00:27 +213: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: G-2 undersized-candidate rule (b) the loader's export PURPOSE stays lenient (unreachable from the shipped export path — see F4 note above)
00:27 +214: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: G-2 undersized-candidate rule A-6: browse-only RAW (.cr2) stays lenient — the engine cannot decode it, so strictness would only delete an image the user can currently see
00:27 +215: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: G-2 undersized-candidate rule A-6 re-derived: an undersized candidate in an engine-decodable non-DNG RAW (.arw) now enters RAW decode, because the escape hatch is no longer .dng-gated
00:27 +216: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: G-2 undersized-candidate rule a DNG whose candidate DOES clear 2800 is unaffected on the preview path
00:27 +217: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state (a) preview on a container whose every declared candidate is unreadable now REACHES the decoder instead of failing fast
00:27 +218: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state (c) the sidebar branch is unchanged: still NO_THUMBNAIL
00:28 +219: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state (b) a real preview-less DNG still yields NeedsRawDecode — the valid-miss path did not regress
00:28 +220: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state a container that declares no preview at all is unchanged: NeedsRawDecode with declaredPreviewsUnreadable false
00:28 +221: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state the G-2 undersized rejection is NOT malformed — an intact but small candidate keeps routing to RAW decode
00:29 +222: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state probe: a corrupt container reports malformed, an intact one does not, and a non-TIFF file is not malformed either
00:29 +223: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state AD-022 generalised: an engine-decodable non-DNG RAW whose every declared candidate is unreadable also reaches the decoder, carrying the finding
00:29 +224: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state AD-022 NOT generalised to browse-only RAW: a corrupt .cr2 keeps the uniform unsupported state, because there is no decode to pre-empt
00:30 +225: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state a non-TIFF engine-decodable RAW (.cr3/.raf/.x3f) is never reported as a parse failure; it reaches the decoder
00:30 +226: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: malformed-DNG parse-failure state extractEmbeddedJpeg keeps its contract on the same corrupt input (added API, not a migration)
00:30 +227: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats (setUpAll)
00:30 +227: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats TC-303: a .webp takes the encoded-bitstream branch for all three purposes and returns the file's own bytes
00:30 +228: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats TC-305: a .tif at preview returns NeedsRawDecode with the IFD0 orientation and declaredPreviewsUnreadable == false
00:30 +229: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats TC-305: a .tif with no Orientation tag falls back to 1
00:30 +230: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats TC-306: a .tif at sidebarThumbnail is a failure and NEVER NeedsRawDecode
00:30 +231: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats TC-307: a TIFF header declaring 30000x30000 is IMAGE_TOO_LARGE
00:30 +232: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats TC-307: a TIFF just under the budget still routes to the decoder
00:30 +233: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats TC-313: NativeImageResult still has exactly three variants after the bitmap-format widening
00:30 +234: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-1 bitmap formats (tearDownAll)
00:30 +234: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-2 HEIC (setUpAll)
00:30 +234: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-2 HEIC TC-314: a .heic at preview returns NeedsRawDecode carrying the orientation the probe supplied
00:30 +235: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-2 HEIC TC-314: a null probe answer waves through with orientation 1
00:30 +236: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-2 HEIC TC-315: a .heic at sidebarThumbnail is a failure and NEVER NeedsRawDecode
00:30 +237: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-2 HEIC TC-320: a HEIC declaring 30000x30000 is IMAGE_TOO_LARGE
00:30 +238: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dart_image_loader_test.dart: phase-2 HEIC (tearDownAll)
00:30 +238: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/exif_orientation_test.dart
00:31 +238: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/exif_orientation_test.dart: TC-213 exifTransformFor maps all eight EXIF values
00:31 +239: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/exif_orientation_test.dart: TC-213b an unrecognised orientation is identity, not a guess
00:31 +240: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_probe_test.dart
00:31 +240: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_probe_test.dart: PhotoSource.probeSource (cost gate) TC-072 content, not the extension, decides the rung: the SAME extension yields both answers
00:31 +241: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_probe_test.dart: PhotoSource.probeSource (cost gate) TC-073 every sample DNG is measured, and exactly the known preview-less ones are expensive
00:31 +242: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_probe_test.dart: PhotoSource.probeSource (cost gate) TC-074 the SAME file changes rung when the requested size changes
00:31 +243: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_probe_test.dart: PhotoSource.probeSource (cost gate) TC-075 probing costs at most 300KB of reads, and a JPEG costs 2 bytes
00:31 +244: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_probe_test.dart: PhotoSource.probeSource (cost gate) TC-076 an unmeasurable file is UNDETERMINED, not expensive
00:31 +245: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_single_probe_test.dart
00:32 +245: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_single_probe_test.dart: single-probe seam TC-090 the whole probe is ONE file open
00:32 +246: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_single_probe_test.dart: single-probe seam TC-091 the fused orientation equals the dedicated reader
00:32 +247: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_single_probe_test.dart: single-probe seam TC-092 the combined probe reads at most 300KB, and a JPEG still costs 2 bytes
00:32 +248: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_single_probe_test.dart: TC-094 emptying the caller list mid-load does not crash preloadImages
00:32 +249: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_single_probe_test.dart: TC-093 an expensive item reaches its RAW decode with ZERO loader calls
00:32 +250: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart
00:32 +250: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-060 eviction order is identical when the payload KINDS are swapped
00:32 +251: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-061 eviction with priority set evicts the FARTHEST item, not the oldest (user ruling 2026-08-27)
00:32 +252: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-300 over-budget put evicts the farthest id, not the oldest
00:32 +253: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-301 selected (first-priority) item survives even when it is the oldest entry
00:32 +254: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-062 peek does not count as a use
00:32 +255: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-063 a payload larger than the whole budget is still retained
00:32 +256: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-064 retainOnly drops exactly the ids outside the window and reports them
00:32 +257: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-065 the retention window is -3..+5, clamped at both ends
00:32 +258: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-219 retentionWindowIds honours explicit before/after
00:32 +259: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_payload_cache_test.dart: PhotoPayloadCache (D4: retention is type-blind) TC-220 retentionWindowIds defaults are still -3..+5
00:32 +260: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_pixels_image_test.dart
00:32 +260: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_pixels_image_test.dart: RawPixelsImage (I1: buffer identity IS the cache key) TC-066 equal CONTENT in a different buffer is a different key
00:32 +261: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_pixels_image_test.dart: RawPixelsImage (I1: buffer identity IS the cache key) TC-067 resolving the same buffer twice decodes once
00:32 +262: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_pixels_image_test.dart: RawPixelsImage (I1: buffer identity IS the cache key) TC-068 eviction disposes the cache's own image and touches nothing the pipeline owns
00:32 +263: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart
00:33 +263: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-095 every slot of the -3..+5 retention window holds a tier-1 entry (AC2)
00:33 +264: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-096 an item at -3 and one at +5 keep their tier-1 entries while in-window, and lose them on leaving (AC2 killer)
00:33 +265: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-097 tier-2 full-size entries cover -1..+3 after the debounce settles (AC3)
00:33 +266: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-098a an all-expensive folder fills the WHOLE -3..+5 payload window, not just +/-1 (criterion 2)
00:34 +267: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-098b at most ONE expensive decode is ever in flight, while cheap window loads still issue in parallel (criterion 3)
00:34 +268: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-098c fresh settle decode START order is 0, +1, -1, +2, -2, +3, -3, +4, +5 (criterion 4)
00:34 +269: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-098d navigating mid-queue reprioritises the lane: no decode starts outside the new window, and the next one is its nearest missing item (criterion 5)
00:34 +270: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-099 widening tier-1 creates no payloads of its own
00:35 +271: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_window_test.dart: TC-100 the two budget constants are pinned as raw byte counts
00:35 +272: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/cache_budget_test.dart
00:35 +272: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/cache_budget_test.dart: budget derivation: floor 256MiB, ceiling 768MiB, quarter of physical
00:35 +273: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart
00:36 +273: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: D2: a browse-only RAW (.cr2) that has no embedded preview stays a preview-only permanent miss -- it never reaches the full decoder
00:36 +274: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: AC3: NativeImageResult has exactly three variants, proven by an exhaustive switch with no default case (a fourth variant fails to compile here, not just at runtime)
00:36 +275: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: a DngFullDecoder/DngSizedDecoder fake wired through the controller reaches an engine-decodable non-DNG RAW when the loader signals NeedsRawDecode -- proves the full-size path is format-agnostic once the loader routes correctly (photo_source.dart already dispatches NativeImageNeedsRawDecode to dngDecoder regardless of extension; the remaining gate lives in dart_image_loader.dart, owned by T2)
00:36 +276: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: AC5 D3: an engine-decodable RAW with no configured native decoder (a platform with no native library) is a permanent miss carrying the D3 no-native-decoder code -- distinct from a decoder that exists but throws
00:36 +277: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: AC5 D3 negative: a THROWING decoder (decoder exists but failed) is a permanent miss WITHOUT the D3 no-native-decoder code -- not conflated with the no-decoder-on-this-platform state
00:36 +278: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: PhotoSource.load: decoder == null carries kNoNativeDecoderCode directly on SourceOutcome.failureCode (unit-level proof, below the controller seam)
00:36 +279: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: PhotoSource.load: every other outcome (bytes, throwing decoder, NativeImageFailure) carries a null failureCode -- the field must not leak into unrelated paths
00:36 +280: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/raw_coverage_wiring_test.dart: D2 sidebar fix: a browse-only RAW (.cr2) never invokes the sized sidebar decoder, even though isRawPath(".cr2") is true -- the gate must be isDecodablePath, not isRawPath
00:36 +281: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart
00:37 +281: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart: small payloads pass through untouched (identity, same object)
00:37 +282: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart: TC-172 a payload at exactly reencodeThreshold passes through byte-identical
00:37 +283: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart: TC-173 oversized payloads are re-encoded as JPEG, long edge capped at 200
00:37 +284: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart: TC-174 undecodable oversized input falls back to the original bytes
00:37 +285: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart: TC-175 jpegFromOrientedPixels bakes EXIF orientation 6 (90 CW) into a decodable JPEG
00:37 +286: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart: TC-176 jpegQuality is tunable and changes the encoded size
00:37 +287: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/sidebar_thumbnail_codec_test.dart: TC-217 sidebarCacheBytes still returns decodable JPEG
00:37 +288: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart
00:37 +288: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart: (setUpAll)
00:37 +288: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart: TC-319: the probe seam routes by container family a .tif is read by the IFD0 walker, not the HEIF probe
00:37 +289: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart: TC-319: the probe seam routes by container family a .heic is read by the HEIF probe, not the IFD0 walker
00:37 +290: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart: TC-319: the probe seam routes by container family an unavailable HEIF probe yields null, never a throw
00:37 +291: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart: TC-319: the probe seam routes by container family a throwing HEIF probe is swallowed into null
00:37 +292: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart: TC-319: the probe seam routes by container family bitmapContainerOrientation falls back to 1 when nothing answers
00:37 +293: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_container_probe_test.dart: (tearDownAll)
00:37 +293: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart
00:38 +293: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-231 isReady is false when nothing has been registered
00:38 +294: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-232 isReady is false while the entry is PENDING, not just missing
00:38 +295: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-233 isReady is true once the decode listener has fired
00:38 +296: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-234 isReady goes false when the payload object is replaced
00:38 +297: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-235 isReady goes false when the ImageCache entry is evicted underneath
00:38 +298: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-236 hasFullResEntryFor is true BEFORE the ready flag fires (AC-M5-4)
00:38 +299: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-237 the full-res failure memo is per payload object, not per id
00:38 +300: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/tier_two_registry_test.dart: TC-238 evict drops one id and clear drops every id
00:38 +301: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_sequential_decode_retention_test.dart
00:38 +301: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_sequential_decode_retention_test.dart: TC-086 expensive post-debounce RAW execution is sequential
00:38 +302: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_sequential_decode_retention_test.dart: TC-088 cheap and expensive payloads retain identically at -3 and evict identically at -4
00:39 +303: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_sequential_decode_retention_test.dart: TC-089 cheap full retention-window source loads overlap
00:39 +304: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart
00:39 +304: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: TC-218 a thumbnail load in flight does not mark the id as loading
00:39 +305: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: preloadImages evicts preview cache entries outside the sliding window
00:39 +306: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: preloadImages loads the selected item first, then the rest of the window concurrently
00:39 +307: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: selecting an in-flight item still fires notify once its load completes (R3: no permanent spinner strand)
00:39 +308: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: tierOneProviderFor produces an identical ImageCache key for the same bytes object identity and same width/height (AC2: display and precache must share one cache entry, not silently double-decode)
00:39 +309: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: precache-then-display resolves as an ImageCache hit (AC2 integration: no second decode once the tier-1 entry is warm)
00:39 +310: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: tier-2 full-size decode does not start until the navigation debounce elapses (AC3a)
00:40 +311: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: tier-2 never queues an item that scrolled out of the window during continuous navigation (AC3b)
00:40 +312: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: tier-1 and tier-2 caches coexist: evicting a tier-2 entry does not evict the tier-1 entry for the same item (AC3c)
00:41 +313: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: isFullSizeReady does not report stale readiness after an item leaves and re-enters the bytes window with a new bytes object (round-2 review BLOCKER 1)
00:42 +314: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: isFullSizeReady stays false while the tier-2 decode is still PENDING, not just when it is missing (round-2 review BLOCKER 3)
00:42 +315: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-077 an expensive item is sourced ONCE and its payload serves both tiers
00:42 +316: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-078 an expensive payload survives leaving the +/-1 STARTUP window and is dropped only on leaving the -3..+5 RETENTION window
00:43 +317: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-079 leaving the tier-2 window evicts the ImageCache entry while the payload stays retained
00:44 +318: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-080 dispose() with a source still in flight destroys nothing and leaks no handle
00:44 +319: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-081 reset() drops every payload and every ImageCache entry
00:44 +320: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-082 an expensive item is requested from the native loader exactly ONCE across repeated in-window passes
00:45 +321: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-083 retained cost stays bounded by the window across a long sweep
00:45 +322: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-084 a source that lands AFTER its item left the window cannot resurrect a retained entry
00:46 +323: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path TC-085 decoder throws marks a permanent miss immediately (no legacy channel left to fall back to, M6 U-12) and never asks again
00:47 +324: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path NO DECODER: an immediate permanent miss, not a spinner
00:47 +325: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path THROWING DECODER: an immediate permanent miss, not a spinner
00:47 +326: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_test.dart: raw-decode path an ordinary (bytes) item is untouched by the raw-decode path
00:47 +327: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_decoder_smoke_test.dart
00:47 +327: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_decoder_smoke_test.dart: decodeDngFull decodes the vivo sample at full resolution
Shell: [DngNativeBindings] loaded: /Users/jhangyu/project/ceyx-heic/plugin/macos/Libraries/libdng_decoder_native.dylib
Shell: [Pipeline] GPU backend: metal (available=yes)
00:48 +328: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_buffer_copy_semantics_test.dart
00:48 +328: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_buffer_copy_semantics_test.dart: AC-B1: extractFullSizeEmbeddedJpeg result is unaffected by mutating the source buffer after the call
00:49 +329: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart
00:49 +329: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 1 maps every pixel correctly
00:49 +330: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 2 maps every pixel correctly
00:49 +331: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 3 maps every pixel correctly
00:49 +332: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 4 maps every pixel correctly
00:49 +333: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 5 maps every pixel correctly
00:49 +334: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 6 maps every pixel correctly
00:49 +335: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 7 maps every pixel correctly
00:49 +336: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) orientation 8 maps every pixel correctly
00:49 +337: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) an unrecognised orientation degrades to no transform
00:49 +338: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToImage orientation (AC B3) a buffer that disagrees with the dimensions is rejected
00:49 +339: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: applyExifOrientation caller-owns contract returns src ITSELF for orientation 1, with no copy
00:49 +340: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: applyExifOrientation caller-owns contract never disposes src, for either the identity or a real transform
00:49 +341: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 1 survives the window downscale
00:49 +342: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 2 survives the window downscale
00:49 +343: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 3 survives the window downscale
00:49 +344: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 4 survives the window downscale
00:49 +345: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 5 survives the window downscale
00:49 +346: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 6 survives the window downscale
00:49 +347: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 7 survives the window downscale
00:49 +348: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-069 orientation 8 survives the window downscale
00:49 +349: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-070 a frame already smaller than the window is NOT upscaled
00:49 +350: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: decodedRgbaToPixelPayload (M3 step 3) TC-071 the retained buffer is the DOWNSCALED size, not the decoded size
00:49 +351: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/decoded_rgba_image_provider_test.dart: TC-311: a TIFF with Orientation 6 renders 90 degrees clockwise, swapping width and height exactly once
00:49 +352: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_decode_wiring_test.dart
00:49 +352: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_decode_wiring_test.dart: (setUpAll)
00:49 +352: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_decode_wiring_test.dart: a .tif reaches the sidebar sized decoder
00:50 +353: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_decode_wiring_test.dart: a D2 browse-only .cr2 does NOT reach the sidebar sized decoder
00:50 +354: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_decode_wiring_test.dart: a .webp does NOT reach the sidebar sized decoder
00:50 +355: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/bitmap_decode_wiring_test.dart: (tearDownAll)
00:50 +355: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart
00:51 +355: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: (setUpAll)
00:51 +355: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: dispatchFullDecode TC-309: routes .tif and .tiff to the TIFF arm
00:51 +356: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: dispatchFullDecode TC-309: routes .dng and .arw to the engine arm
00:51 +357: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: dispatchFullDecode TC-309: throws UnsupportedError for an unroutable extension
00:51 +358: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: dispatchSizedDecode TC-309: routes .tif to the TIFF arm and .dng to the engine arm
00:51 +359: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: TIFF arm decodes a real TIFF to a self-consistent RGBA buffer
00:51 +360: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: TIFF arm honours maxDim as a downscale request
00:51 +361: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: TIFF arm throws on a TIFF package:image cannot decode
00:51 +362: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: TIFF arm TC-308: the sized arm refuses an over-budget extent BEFORE any decode is attempted
00:51 +363: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: TIFF arm TC-308: an in-budget TIFF still reaches the decoder on the sized path
00:51 +364: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: phase-2 HEIC arm TC-309: routes .heic/.heif to the HEIF arm, never to TIFF or RAW
00:51 +365: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: phase-2 HEIC arm TC-309: the sized path routes .heic to the HEIF arm with maxDim
00:51 +366: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: phase-2 HEIC arm TC-316: an unavailable HEIF library becomes a decoder throw, not a crash and not the D3 no-decoder state
00:51 +367: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: phase-2 HEIC arm TC-316: PhotoSource turns that throw into the uniform permanent miss, with failureCode null
00:51 +368: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: phase-2 HEIC arm TC-317: a length/geometry mismatch is rejected before it can reach decodeImageFromPixels
00:51 +369: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: phase-2 HEIC arm TC-317: a consistent buffer passes through unchanged
00:51 +370: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/full_decoder_dispatch_test.dart: (tearDownAll)
00:51 +370: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart
00:51 +370: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart: P1 translated: cheap DNG has tier-1 entries at arrival; expensive cold arrival fills the same window, one decode at a time
00:52 +371: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart: TC-088 probe-first expensive item: selected distance 0 has ZERO loader calls before debounce
00:52 +372: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart: TC-088 probe-first expensive item: plus-one distance 1 has ZERO loader calls before debounce
00:52 +373: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart: TC-088 probe-first expensive item: outer retention distance 3 has ZERO loader calls before debounce
00:52 +374: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart: P2 translated: navigation bursts never exceed one expensive decode in flight and never decode out-of-window items, while cheap DNGs/JPEGs prefetch during the same burst
00:53 +375: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart: P3 translated: one-step expensive round trip decodes once and retains the PixelPayload
00:54 +376: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_probe_first_navigation_test.dart: P4 translated: two-step expensive excursion decodes once and retains the payload; JPEG bytes still survive identically
00:58 +377: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart
00:59 +377: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart: M4-AC1 a permanently failing sidebar thumbnail is requested EXACTLY ONCE across three preloadThumbnails sweeps
01:00 +378: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart: M4-AC1b a failed sidebar thumbnail must not poison the PREVIEW state of a file whose own name happens to be "thumb_" + another file's name
01:00 +379: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart: M6-PL1 a throwing sidebar thumbnail loader must not abort the sweep, must release the in-flight key, and must record a permanent miss like a non-bytes result
01:01 +380: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart: M4-AC2 a stale preloadImages resume must not reschedule tier-2 for the window it started with (invariant I4)
01:02 +381: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart: M6-PL7 the SECOND generation guard (after the window await, :406) must discard a stale resume too, not only the priority-load guard (:381)
01:02 +382: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart: M4-AC3 step-3b failure inside PhotoSource.load reports a NON-deferred null payload -- the signal the caller turns into a permanent miss
01:02 +383: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_permanent_miss_test.dart: M4-AC3 the step-3b failure path marks a permanent miss and RELEASES the view from its spinner (invariant T1)
01:02 +384: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart
01:03 +384: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart: M5-DW1 tier-2 keys equal the +/-2 band after settle, for encoded and pixel payloads alike
01:06 +385: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart: M5-DW2 a pixel-backed item at distance 0 gets a FULL-resolution tier-2 entry distinct from its window-resolution tier-1 entry
01:06 +386: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart: M5-DW3 payload production and full-res tier-2 for a RAW item inside +/-1 cost exactly ONE decoder call
01:06 +387: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart: M5-DW4 leaving +/-2 evicts the full-res entry; re-entering re-upgrades with exactly one extra decoder call and an identical retained payload
01:07 +388: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart: M5-DW5 a failing full-res decode keeps tier-1 display, writes NO permanent miss, and is not retried for the same payload
01:09 +389: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart: M5-DW6 a full-res upgrade adds ZERO bytes to the payload cache
01:09 +390: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart
01:09 +390: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: synthetic_dng helper is deterministic: identical arguments give identical bytes
01:10 +391: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: synthetic_dng helper writes the requested byte-order marker
01:10 +392: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: synthetic_dng helper the II build is readable at all (differential sanity floor)
01:10 +393: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: MM equals II selected dims at longEdge: 200
01:10 +394: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: MM equals II selected dims at longEdge: null
01:10 +395: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: MM equals II extracted bytes are byte-identical
01:11 +396: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: MM equals II orientation matches
01:11 +397: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_endian_test.dart: corruptOffsets stays walkable but yields no extractable candidate
01:11 +398: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart
01:11 +398: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: sample directory has both required fixtures
01:11 +399: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: a .dng that fails the native preview channel recovers the embedded JPEG through the controller, byte-identical to the extractor
01:12 +400: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: a .dng with no embedded preview still falls through to hasFailed, not a crash, when the native preview channel fails
01:12 +401: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: a real DNG saved under a .jpg extension is recovered through the seam once the native preview channel fails (F-08: the walker keys on magic, not extension)
01:12 +402: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: non-TIFF garbage saved under a .jpg extension is still a permanent miss when the native preview channel fails (proves the magic check, not the extension, is what discriminates)
01:12 +403: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: fallbackAfterNativeFailure recovers a non-DNG RAW with an embedded preview (extension gate removed)
01:12 +404: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: AD-022 after the pre-empt override: the two no-preview states stay distinguishable once the decode outcome is known previews declared but unreadable AND the decode also failed surfaces the broken-file code
01:12 +405: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: AD-022 after the pre-empt override: the two no-preview states stay distinguishable once the decode outcome is known no preview declared and the decode failed stays the uniform miss, NOT the broken-file code
01:12 +406: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: AD-022 after the pre-empt override: the two no-preview states stay distinguishable once the decode outcome is known the two codes actually differ — the states are not collapsed
01:12 +407: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: AD-022 after the pre-empt override: the two no-preview states stay distinguishable once the decode outcome is known a container with unreadable previews whose decode SUCCEEDS is not reported broken at all — the point of the override
01:12 +408: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: AD-022 after the pre-empt override: the two no-preview states stay distinguishable once the decode outcome is known the broken-file code is NOT the D3 no-native-decoder state
01:12 +409: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: TC-310: a corrupt TIFF is an ordinary permanent miss a throwing decoder on a TIFF yields failureCode null, NOT DNG_PARSE_FAILED
01:12 +410: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/photo_source_test.dart: TC-310: a corrupt TIFF is an ordinary permanent miss the DNG_PARSE_FAILED arm is still reachable for a RAW container with unreadable declared previews
01:12 +411: loading /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart
01:12 +411: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC2: smallest candidate >= longEdge 200 is the 256x171 preview
01:12 +412: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-19-37-38.dng
01:12 +413: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-20-53-24.dng
01:12 +414: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-20-53-31.dng
01:12 +415: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-20-57-15.dng
01:12 +416: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-20-57-23-2.dng
01:12 +417: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-20-57-23.dng
01:12 +418: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-20-57-26.dng
01:12 +419: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-20-57-28.dng
01:12 +420: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-21-53-33.dng
01:12 +421: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-21-53-41.dng
01:12 +422: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-21-53-42.dng
01:12 +423: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-02-15-21-53-43.dng
01:12 +424: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC3: longEdge 2800 is byte-identical to today's full-size extraction 2026-08-07-17-52-54.dng
01:12 +425: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC4: byte-range read budget stays bounded across every .dng sample
01:12 +426: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC5: sole 6000x4000 candidate is selected, orientation 6, APP1 injected
01:12 +427: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC6: no-candidate/missing/non-DNG inputs return null, never throw DNG with no qualifying candidate returns null
01:12 +428: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC6: no-candidate/missing/non-DNG inputs return null, never throw nonexistent path returns null
01:12 +429: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC6: no-candidate/missing/non-DNG inputs return null, never throw plain-JPEG file (not a DNG/TIFF container) returns null
01:12 +430: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC11a: readOrientation reads IFD0 tag 0x0112 via the bounded walk (discriminating case)
01:12 +431: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC11b: readOrientation on a no-preview DNG stays under the disk-read budget
01:12 +432: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC12a: readOrientation on a nonexistent path returns null, never throws
01:12 +433: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC12b: a file that parses but carries no 0x0112 tag returns 1
01:12 +434: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC12c: non-TIFF/garbage input returns null, never throws
01:12 +435: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC12h: 0x0112 tag PRESENT but unreadable -> readOrientation null, readDngOrientation 1 (distinct from AC12b's tag-ABSENT case)
01:12 +436: /Users/jhangyu/project/Halcyon-decoders/test/services/image_pipeline/dng_embedded_jpeg_extractor_long_edge_selection_test.dart: AC12d: N1 fixture — large file with a patched non-default orientation tag
01:12 +437: loading /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_coordinator_test.dart
01:13 +437: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_coordinator_test.dart: RenameCoordinator TC-227 an empty rename plan does not clobber the previous batch's undo map
01:13 +438: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_coordinator_test.dart: TC-228 displayProvider returns the identical object currentFullResProvider returns once the full-size decode is ready
01:13 +439: loading /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart
01:13 +439: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: TC-031 sibling RAW + JPG + sidecar all get the same new base
01:13 +440: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: TC-032 same-second items with {seq} number in original-name order
01:13 +441: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: TC-033 collision without {seq} falls back to -1/-2
01:13 +442: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: TC-034 a name already in the folder is never reused
01:13 +443: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: TC-035 an item already named correctly produces no moves
01:13 +444: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: TC-036 missing metadata still renames, using file mtime
01:13 +445: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: apply + undo TC-037 renames every file and reports progress
01:13 +446: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: apply + undo TC-038 undo restores every original name and drops the log
01:13 +447: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: apply + undo TC-039 a missing source is a failure, not an aborted batch
01:13 +448: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: apply + undo TC-040 cancel stops the batch and leaves a replayable log
01:13 +449: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/rename_service_test.dart: apply + undo TC-211 a malformed journal line does not block the undo
01:13 +450: loading /Users/jhangyu/project/Halcyon-decoders/test/services/rename/exif_metadata_service_test.dart
01:14 +450: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/exif_metadata_service_test.dart: TC-045 decodes a full native map
01:14 +451: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/exif_metadata_service_test.dart: TC-046 a null map, a missing date and a junk date all degrade
01:14 +452: /Users/jhangyu/project/Halcyon-decoders/test/services/rename/exif_metadata_service_test.dart: TC-120 readBatch never touches a platform channel
01:14 +453: All tests passed!
RC=0
```

## macOS build, S4 and H1 evidence
See docs/logs/2026-08-28/phase2-macos-build.log; the Step-4 checks are reproduced here:
```
    [ok]   cmake build (dng_decoder_native)
    [ok]   cmake build (test_cfa_color)
[CFA COLOR] file=/Users/jhangyu/project/Halcyon/local_data/photo_samples/DNG/IMG_20251112_092839.dng size=4080x3056 band=0.10 samples=1244400 meanR=81.93 meanG=146.90 meanB=214.34 B-R=132.41 min=50.00 [PASS]
    [ok]   cmake build (test_heif_color)
[HEIF COLOR] file=/Users/jhangyu/project/ceyx-heic/native/tests/data/h1_sample.heic size=512x415 pixels=212480 MAE=0.2869 max=2.0000 [PASS]
BUILD_RC=0
```

## TC-318 — H1 native colour gate (evidence attribution)

TC-318 is the H1 known-answer colour gate. It is run natively by `build_apps.py`
Phase 1 (`test_heif_color`), not by `flutter test`, so it does not appear in the
suite output above. Its genuine evidence is the `[HEIF COLOR] … [PASS]` line
reproduced verbatim in the build-evidence block above:

    [HEIF COLOR] file=/Users/jhangyu/project/ceyx-heic/native/tests/data/h1_sample.heic size=512x415 pixels=212480 MAE=0.2869 max=2.0000 [PASS]

MAE 0.2869 ≤ 2.0000, so TC-318 PASSES. (The native binary does not yet embed the
literal "TC-318" in its output line — a ceyx-side parking-lot item; this section
supplies the identifier so the artifact is greppable per the plan's Task 9 rule.)
