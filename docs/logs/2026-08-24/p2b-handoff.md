# P-2b handoff (pl-impl-1-sonnet)

> Written 2026-08-24, mid-task, BEFORE the risky remaining step (full-suite re-run + unit_test.md doc + commit), per lead's post-mortem instruction: write the handoff before running low, not after.

## Task
P-2b (task #9): wire the git build commit into `scripts/build_apps.py` so `--dart-define=HALCYON_BUILD_COMMIT=<hash>` is passed automatically on a real build. Worktree `/Users/jhangyu/project/halcyon-m6`, branch `m6-cleanup`, base tip `1956710`.

## State right now (verify with `git status --porcelain` / `git diff --stat` before trusting this)
Uncommitted, on disk, NOT yet committed:
- `scripts/build_apps.py`: new `git_build_commit(halcyon)` helper (before `def macos_config_name`, ~line 1247) + wired into `build_flutter()` (~line 1430) appending `--dart-define=HALCYON_BUILD_COMMIT={build_commit}` to `build_args`, plus a `step(...)` log line.
- `test/perf_log_build_stamp_test.dart`: new file, sentinel test for proof half 1 (asserts `kHalcyonBuildCommit` from `lib/perf/perf_log.dart` matches a fresh `String.fromEnvironment('HALCYON_BUILD_COMMIT', defaultValue: 'unknown')` re-declared in the test).

## Proof already captured and confirmed (both halves DONE)
- **Half 1** (plumbing reaches Dart): `tmp/verify/p2b-sentinel-default.txt` (bare `flutter test`, RC=0, asserts default `'unknown'`) and `tmp/verify/p2b-sentinel-defined.txt` (same test with `--dart-define=HALCYON_BUILD_COMMIT=deadbeefcafef00d0000000000000000sentinel`, RC=0).
- **Half 2** (script actually passes a real hash): `tmp/verify/p2b-build-half2.txt` — a real `python3 scripts/build_apps.py macos --release` run, `BUILD_RC=0`. Log line 52-54 shows `build commit stamp: 195671031cffb381ea7d1f40d3a683ee7c63f8f7-dirty` and `flutter build macos --release --dart-define=HALCYON_BUILD_COMMIT=195671031cffb381ea7d1f40d3a683ee7c63f8f7-dirty`. The `-dirty` suffix is CORRECT — the tree has uncommitted work (this very change) at build time, which is exactly what the dirty-detection is supposed to catch. `tmp/verify/p2b-binary-grep2.txt` confirms the 40-char hash (`195671031cffb381ea7d1f40d3a683ee7c63f8f7`) is present, grepped straight out of `build/macos/Build/Products/Release/Halcyon.app/Contents/Frameworks/App.framework/Versions/A/App` (the compiled Dart AOT snapshot — NOT the main Mach-O executable, grepping that alone gave 0 hits, don't repeat that mistake on resume).
- `flutter analyze`: 0 issues, `tmp/verify/p2b-analyze.txt`, `ANALYZE_RC=0`.

## NOT yet done (resume here)
1. **`unit_test.md`**: document, next to the existing PL-9 "Artifact provenance" subsection (added in commit `013059b`):
   - Which invocation paths stamp a real hash: only a build that goes through `scripts/build_apps.py`'s `build_flutter()`.
   - Which stamp `unknown`: any hand-invoked `flutter run`/`flutter build` without `--dart-define=HALCYON_BUILD_COMMIT=...`.
   - **Operating rule**: a perf log whose `build.stamp` line reads `commit=unknown` invalidates that measurement run — do not interpret it as "no information, proceed anyway."
   - Register the new test `test/perf_log_build_stamp_test.dart` in the TC-matrix, same pattern as `013059b`/`7b0e323` (next free number — grep `TC-\d+` across `test/` AND `unit_test.md` for the current max; it was TC-110 as of tip `1956710`, so this one is almost certainly TC-111, but RE-VERIFY, don't trust this stale number blindly).
2. **Full suite re-run, count arithmetic PRE-REGISTERED before running**:
   - Baseline at `1956710` (before any of this task's changes) needs re-confirming as exactly 245 executed / 0 skipped — do this as literally the first command on resume, before adding anything, if not already re-confirmed this session.
   - `test/perf_log_build_stamp_test.dart` is a NORMAL suite member (no special invocation needed to make it discoverable — it runs bare and asserts the documented default when no dart-define is passed). So a bare `flutter test -j 1` (full suite) is expected to execute **246** (245 + 1), 0 skipped. Pre-register this number in the artifact BEFORE running, not after reading the result.
   - Re-check the three frozen gate sha256 values unchanged: `59b1f3c7…` (`test/dng_nav_probe_m3_test.dart`), `fcdd564e…` (`test/image_preload_controller_m3_amend3_test.dart`), `05565d33…` (`scripts/tmp/dng_nav_probe_test.dart`).
   - Re-check D4 grep (`grep -c "EncodedPayload\|PixelPayload" lib/services/photo_payload_cache.dart` == 0) and AD-018 radii still separate (`prefetch_scheduler.dart:12`/`:32`).
3. **Commit** — single commit for this whole item (`scripts/build_apps.py` + `test/perf_log_build_stamp_test.dart` + `unit_test.md` changes), explicit `git add` of only those three paths, never `-A`/`.`. Suggested Conventional Commits type: `feat(build)`.
4. **Verify untouched**: confirm `macos/`, `memory.md`, `lib/services/native_thumbnail_service.dart` are still byte-identical to `2a15d74` (`git diff 2a15d74 -- macos/ memory.md lib/services/native_thumbnail_service.dart` should be empty) — this task never touched them, but state it explicitly in the report since the lead re-verifies at sign-off.
5. **Report READY_FOR_SIGNOFF** to `m6-lead-opus` with file:line references for the two code changes, all `tmp/verify/` artifact paths listed above, the commit hash, and the full-suite/analyze results. Do not mark task #9 completed — lead signs off.

## Hard constraints (unchanged, repeated for a resuming session)
Three frozen test files untouched. AD-018/AD-019 untouched. D4 grep stays 0. The two permanent-miss sets stay separate containers. JPEG hot path gains no per-navigation work. Do NOT touch `macos/**`, `memory.md`, `lib/services/native_thumbnail_service.dart`. Git red lines: never `stash`/`reset`/`checkout --`/`clean`; commit only with explicit `git add <own files>`, never `-A`/`.`; never force-push/merge.

## Note on the build artifact this produced
`build/macos/Build/Products/Release/Halcyon.app` now exists on disk with the `-dirty` hash baked in — this is a build ARTIFACT (untracked, under `build/` which CLAUDE.md says stays out of version control), not something to commit or clean up specially. No UI-driven measurement was run against it (standing user directive respected) — it was built solely to grep its command line and binary for proof half 2.
