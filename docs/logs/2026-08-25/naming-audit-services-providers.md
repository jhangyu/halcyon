# Naming audit: lib/services/ + lib/providers/

Date: 2026-08-25
Scope: read-only. All 27 files in `lib/services/` and both files in `lib/providers/` were read in full.

## Files covered

lib/services/: cache_budget.dart, dart_image_loader.dart, decoded_rgba_image_provider.dart,
dng_decode_contract.dart, dng_decode_service.dart, dng_preview_extractor.dart,
exif_metadata_service.dart, exif_orientation.dart, image_preload_controller.dart,
image_source_types.dart, open_with_channel.dart, photo_file_actions.dart,
photo_library_scanner.dart, photo_payload_cache.dart, photo_payload.dart, photo_source.dart,
photo_status_store.dart, prefetch_scheduler.dart, raw_full_res_image.dart, raw_pixels_image.dart,
rename_rule.dart, rename_service.dart, sidebar_thumbnail_codec.dart, thumbnail_export_service.dart,
tier_two_registry.dart, tier_two_scheduler.dart, trash_service.dart.

lib/providers/: app_state.dart, rename_coordinator.dart.

Also read `memory.md` (AD-001 through AD-028, G-001 through G-009) to distinguish deliberate
architecture terminology (e.g. tier-1/tier-2, `kTierTwoRadius` vs `kExpensiveStartupRadius`) from
actual drift before flagging anything.

## Summary verdict

No semantic-drift findings and no stale version/generation-suffix findings in these two
directories. This codebase carries unusually heavy doc-comments that explicitly justify almost
every non-obvious name, including several places that record a past name change and why the new
name is correct (e.g. `AD-020`/`G-004` documents that `NativeThumbnailService` was deleted and
replaced by `dartImageLoad`; the old name does not appear anywhere in current source). The M6/M7/D1
refactor rounds recorded in `memory.md` appear to have already done a naming-consistency pass on
this exact scope. `grep` for common stale markers (`V2`, `New`, `Old`, `Legacy`, `Tmp`, `Temp`,
`Fixed`, trailing `_2`) across both directories returned zero real hits (only an unrelated
`kDefaultTemplate` false-positive on the regex).

One low-severity, non-drift observation is listed below; everything else inspected was intentional
and self-documenting.

## Inconsistent naming (low severity)

1. `lib/services/dng_preview_extractor.dart:271` | `static int readDngOrientation(Uint8List data)`
   | evidence: this method has zero production callers (`grep -rn "readDngOrientation" lib/`
   matches only its own declaration and its own doc comment at line 193). Its only callers are in
   `test/dng_preview_extractor_test.dart` and `test/dng_preview_extractor_m0_test.dart`, and the
   M0 test's own description calls it "legacy `readDngOrientation`" (line 382). The doc comment at
   `dng_preview_extractor.dart:193` explicitly frames it as "the deliberate asymmetry with
   `[readDngOrientation]`" against the still-used async `readOrientation` (used by
   `dart_image_loader.dart:109` and `image_preload_controller.dart:853`).
   | proposed name: no rename needed — the name itself is accurate (it does read DNG orientation).
   Flagging only because it is production-dead and test-only under a name that reads as a normal
   production API; if kept, consider `@visibleForTesting` or a name that signals its
   test/legacy-parity role (e.g. `readDngOrientationLegacy`) so a future reader does not assume it
   is reachable from the app.
   | usage count: 2 files, ~6 call sites, all in `test/`.
   | risk: test-referenced only, not part of any public/production API surface. Renaming would
   require touching two test files and is out of scope for a read-only audit — recorded here as an
   observation, not a rename recommendation with priority.

## Not flagged (checked, found deliberate)

- `readOrientation` (async, IO-based) vs `readDngOrientation` (sync, in-memory) in
  `dng_preview_extractor.dart` — doc-commented deliberate asymmetry (return contract: nullable vs
  folds-to-1), not accidental duplication.
- `tierOneProviderFor` / `fullSizeProviderFor` / `kTierTwoRadius` / `kExpensiveStartupRadius` —
  documented architecture vocabulary (AD-011, AD-018); not stale, not drift.
- `TierTwoRegistry` vs `TierTwoScheduler` — deliberately two units per AD-027/AD-028, with an
  explicit "must not be re-joined" rule; not a naming collision.
- `PhotoPayloadCache` doc calls out that it behaves as FIFO not LRU (AD-023) but the class name
  itself makes no LRU claim, so no rename needed.

## Acceptance criteria

1. Report covers every `.dart` file in `lib/services/` and `lib/providers/` — done (29 files listed above).
2. Every finding has file:line + evidence + proposed name + usage count — done (1 finding).
3. No code files modified — confirmed, only this report file was written.

## Uncertain / not done

None. Full read of every file in scope was completed; no time-boxing was needed given the file count.
