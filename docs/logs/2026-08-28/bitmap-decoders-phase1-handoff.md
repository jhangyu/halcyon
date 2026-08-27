# Bitmap decoders — Phase 1 handoff (WebP + TIFF landed; HEIC next)

## Contract (verbatim from spec §10, phase 1)
Terminal state: WebP and TIFF files display through the existing image pipeline (sidebar, preview, export) on every platform, with no new pub dependency and the frozen three-variant `NativeImageResult` seam untouched.

## State: PHASE 1 COMPLETE on `feature/bitmap-decoders` (worktree /Users/jhangyu/project/Halcyon-decoders)
- Spec: `docs/superpowers/specs/2026-08-28-bitmap-decoders-design.md` (d6f0d60)
- Plan: `docs/superpowers/plans/2026-08-28-bitmap-decoders-phase1.md` (8ed3bd8)
- Code commits: 938292e (registry) → 998e275 (loader) → 57c8de4 (dispatcher) → 2d92b9f (wiring) → d104f7c (e2e pins) → 6f3b173 (docs + gate)
- Gate: `docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md` — analyze RC=0 "No issues found!", `flutter test -j 1` RC=0 "+436 All tests passed!" at d104f7c; 6f3b173 is docs-only on top.
- Fresh review (reviewer-round1-sonnet): mergeable, zero blocker/should-fix. Frozen seam untouched, AD-021/AD-022 gates still on `isDecodablePath`, budget enforced on both loader and sized paths.

## Environment facts a successor must know
- `local_data` in the worktree is a SYMLINK to /Users/jhangyu/project/Halcyon/local_data (sample corpus, gitignored). Without it the full suite shows 59 sample-dependent failures — that is the environment, not the code.
- SOP docs (memory.md, unit_test.md, file_index.md) live at /Users/jhangyu/project/Halcyon/docs/sop/, gitignored, edited IN PLACE only at merge time (see below). Never committed.
- The native package is `ceyx` at /Users/jhangyu/project/ceyx (pubspec path `../ceyx/plugin`). CLAUDE.md's `../flutter_dng_decoder/dng_processor` path is stale.
- Other sessions work on Halcyon main — never touch /Users/jhangyu/project/Halcyon except the read-only SOP/read paths above.

## Pending at merge-to-main time (owner: team lead)
1. Plan Task 6 Step 6: in-place SOP edits — memory.md AD-035 (routing argument, hasFullDecodeRoute vs isDecodablePath split), unit_test.md rows TC-302..TC-313, file_index.md row for full_decoder_dispatch.dart. Then Step 7 verification (grep the markers, confirm nothing entered git).
2. Post-merge full-suite re-run on main (lessons-learned 2026-08-16: in-branch green does not prove the cross-branch combination).

## Pending user-owned check
Open a folder containing one WebP and one TIFF: both should appear in the sidebar and render in the detail view. (UI checks belong to the user by standing rule.)

## Parking-lot (reported, deliberately not acted on)
- WebP EXIF orientation not applied by the engine (phase-1 stated gap).
- Encoded-bitstream branch (JPEG/PNG/WebP) still outside the decoded-pixel budget (pre-existing).
- TIFF export inherits the strict preview floor: with no decoder available, sub-~3111px-long-edge no-preview files fail export where an undersized rendition once appeared (pre-existing for .dng, widened knowingly).
- Multi-page TIFF: page 0 only.
- Plan self-defects: two acceptance greps collide with plan-mandated comment text (documented in impl-1 report); package:image throws TypeError (not null) on header-only TIFF.

## Phase 2 (HEIC) — next
- Spec §7: libheif + libde265, decode-only, DYNAMIC linking (LGPL-3 §4(d)(1)), integrated into ceyx native build; H1 known-answer gate (sample HEIC vs reference PNG, MAE ≤ 2/255); S4 colour gate must still pass (same artifact rebuilt) but is not extended to HEIC.
- Version pins 1.19.x / 1.0.15 are UNVERIFIED targets — confirm upstream before pinning SHAs.
- Windows/Linux acceptance is scoped to macOS readiness; those OS builds are first-contact later.
- Shared-state red line: ceyx working tree at /Users/jhangyu/project/ceyx is consumed live by main-tree sessions. HEIC work must happen in a ceyx WORKTREE (e.g. /Users/jhangyu/project/ceyx-heic, branch feature/heic-decode); Halcyon-decoders' pubspec may point there only inside this worktree and must be reverted to `../ceyx/plugin` before merge, with the ceyx branch merged to ceyx main in the same operation.

## Refuted routes (do not retry)
- Adding a 4th NativeImageResult variant (AD-010/011 freeze; spec §4.2 rejected it).
- Transcode-to-bytes inside dart_image_loader (breaks "loader never decodes", kills AD-022 verdict formation).
- OS-decoder HEIC route (user explicitly rejected; cross-platform parity required).
