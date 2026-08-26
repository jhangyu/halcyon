# Structure Cleanup — Convergence Contract (frozen 2026-08-26)

Frozen by the user. Only the user may amend. Round budget: 2.

## End state (one sentence)

Every straggler identified by the 2026-08-26 structure audit is removed or corrected, the
repository's tracked file set matches what `.gitignore` and the project SOP claim it should be,
and `flutter analyze` reports zero issues while the full test suite passes with no test lost.

## In scope

Deletions (A/B/C7), corrections (C1–C6), the documentation index (C8), and the coupled edits that
each deletion forces (dangling comments, stale ignore-file prose, stale doc references).

## Out of scope (do NOT do these, even if they look tempting)

- Renaming or reorganising anything not listed in the acceptance criteria below.
- Touching `../ceyx/` (the sibling native decoder package) in any way.
- Rewriting historical logs under `docs/logs/` other than the one `.txt` deletion and the new
  `INDEX.md`. Historical logs are append-only records; stale paths inside them are correct history.
- Committing. The lead commits once, after the gate passes.
- `docs/mockups/` (assessed as legitimate; not part of C8).

## Acceptance criteria (each mechanically checkable)

| # | Criterion | Command that decides it |
|---|---|---|
| AC-1 | `scripts/tmp/` is fully untracked (all 42 files removed from the index) | `git ls-files scripts/tmp \| wc -l` → `0` |
| AC-2 | `assets/` tracks exactly `icon.png` and `icon.svg`; `assets/icons/` is gone | `git ls-files assets` → exactly 2 lines: `assets/icon.png`, `assets/icon.svg` |
| AC-3 | The 25 MB Windows hand-off zip is no longer inside `assets/` | `ls assets/*.zip` → no such file |
| AC-4 | `docs/flutter_app_README.md` deleted | `git ls-files docs/flutter_app_README.md \| wc -l` → `0` |
| AC-5 | No non-`.md` file remains under `docs/logs/` | `find docs/logs -type f ! -name '*.md'` → empty output |
| AC-6 | `docs/logs/INDEX.md` exists and indexes every date folder and every `.md` log with a one-line purpose | file exists; `grep -c '^' docs/logs/INDEX.md` > 100; every date folder name appears in it |
| AC-7 | `windows/runner/halcyon_associations.reg` untracked and ignored; its generator is unchanged | `git ls-files windows/runner/halcyon_associations.reg \| wc -l` → `0`; `git check-ignore -v windows/runner/halcyon_associations.reg` → matches a rule; `git diff --stat scripts/gen_windows_associations.dart` → no change |
| AC-8 | `scripts/check_dng_ffi_artifacts.py` and its JSON manifest are RETAINED; the script's docstring gains one line stating it is a manually-run cross-platform FFI artifact check, not an automated gate | both files still tracked; `python3 scripts/check_dng_ffi_artifacts.py; RC=$?` → `RC=0` |
| AC-9 | CI's build job calls the single build entry point instead of `flutter build` directly | `grep -n 'flutter build macos' .github/workflows/ci.yml` → `0` hits; `grep -n 'build_apps.py' .github/workflows/ci.yml` → ≥1 hit |
| AC-10 | The analyzer exclusion is narrowed so live build tooling is analysed | `grep -n 'scripts/\*\*' analysis_options.yaml` → `0` hits; `grep -n 'scripts/tmp/\*\*' analysis_options.yaml` → ≥1 hit |
| AC-11 | `lib/perf/perf_log.dart`'s "CONTRACT consumed by ..." comment no longer names a deleted file | `grep -n 'scripts/tmp' lib/perf/perf_log.dart` → `0` hits |
| AC-12 | Test-file header comments no longer point at deleted scratch scripts | `grep -rn 'scripts/tmp/run_dng_extractor_tests\|scripts/tmp/dng_nav_probe_test' test/` → `0` hits |
| AC-13 | The stale group title naming a removed method is fixed | `grep -n 'PhotoSource\.probe (' test/services/image_pipeline/photo_source_probe_test.dart` → `0` hits |
| AC-14 | `test/widget_test.dart` is gone and its scenario survives | `git ls-files test/widget_test.dart \| wc -l` → `0`; the empty-folder-prompt scenario present in `test/main_test.dart`; total test count not reduced |
| AC-15 | No test filename encodes a milestone/ticket code | `git ls-files test \| grep -cE '_(m[0-9]+\|f3)(_\|\.)'` → `0` |
| AC-16 | `.gitignore`'s prose about "42 files tracked before this rule" is corrected to match reality | `grep -n '42 files' .gitignore` → `0` hits |
| AC-17 | Zero dangling references to any deleted path outside `docs/logs/` history | for each deleted path P: `grep -rn "P" lib/ test/ tool/ scripts/ *.md .github/ pubspec.yaml analysis_options.yaml` → `0` hits |
| AC-18 | **Global gate**: analyzer clean and full suite green | `flutter analyze` → `No issues found!` with `RC=0` self-captured in the artifact; `flutter test -j 1` → `All tests passed!`, declared test count == executed count, `RC=0` self-captured in the artifact, zero `[E]` markers |

## Red lines (every member)

- NEVER run `git stash`, `git reset`, `git checkout --`, or `git clean`. Teammates' uncommitted work
  in the tree is normal.
- Do NOT commit. Stage nothing. The lead commits once after AC-18 passes.
- Deletions use `git rm` (index + worktree) so the index reflects the change without a commit.
- Only modify files in your ownership list. Message the lead before touching anything else.
- Do not weaken, skip, or rewrite a test to make the gate pass. A failing gate is a report, not a
  thing to route around.
- Exit codes are captured with `RC=$?` on the line immediately after the command, written INTO the
  artifact file. Never trust a harness-reported exit code, never use `${PIPESTATUS[0]}`.

## File ownership

| Member | Owns |
|---|---|
| `impl-infra-sonnet` | `scripts/**`, `assets/**`, `.gitignore`, `.github/workflows/ci.yml`, `analysis_options.yaml`, `windows/runner/halcyon_associations.reg`, `lib/perf/perf_log.dart` (comment only), `README.md` |
| `impl-docs-sonnet` | `docs/flutter_app_README.md`, `docs/logs/2026-08-23/round-1-m1-independent-review.txt`, `docs/logs/INDEX.md` (new) |
| `impl-tests-sonnet` | `test/**`, `unit_test.md` |
| lead (main agent) | `file_index.md`, `memory.md`, `task.md`, `handover.md`, `plan.md`, this contract |
| `test-runner-haiku` | writes only under `tmp/verify/` |

## Recorded deviations (lead rulings, round 1)

| # | Criterion | What happened | Ruling |
|---|---|---|---|
| D-1 | AC-7 vs AC-10 | AC-10 (narrowing the analyzer exclude to `scripts/tmp/**`) newly subjected `scripts/gen_windows_associations.dart` to analysis, which failed `avoid_relative_lib_imports`. Fixing it changed that file, contradicting AC-7's `git diff --stat … → no change` sub-check. | ACCEPTED. AC-7's sub-check exists to guard against **behaviour** drift, and the lead verified behaviour directly: `dart run scripts/gen_windows_associations.dart` → `RC=0`, and the emitted `windows/runner/halcyon_associations.reg` is byte-identical before and after (`md5 06f9102b4a2823e95ab2e0fc9879d386` both times, 9 extensions). A behaviour-preserving import-style fix forced by another criterion satisfies AC-7's intent. |
| D-2 | AC-15 scope | The work item named 7 files; the criterion's decider is a grep pattern, and an 8th file (`test/views/sidebar_view_m1_test.dart`) matched it. The implementer renamed it too and flagged the discrepancy. | ACCEPTED as in-scope. The grep is the decider; leaving the 8th file would have failed the criterion. Drafting gap in the contract, not implementer overreach. |
| D-3 | AC-17 scope | Dangling-looking `scripts/tmp/...` references remain in `tool/m6_dng_gate/*` and the root SOP markdown files. | NO ACTION. The lead checked each: none names any of the 42 deleted files. Every one points at `final-gate.txt`, `m6-r1-bench/`, `m6-r2-verify/`, `m7-t*/`, `verify/` — always-untracked gitignored scratch, already outside the repo before this round. They are historical evidence citations, same category as `docs/logs/`. |
| D-4 | Lead-side addition | While syncing `file_index.md`, the lead corrected one adjacent line that was demonstrably false (`macos/Runner/AppDelegate.swift` was described as hosting a `getThumbnail` handler and a `halcyon/exif` handler; it registers only `halcyon/trash` and `halcyon/open_with`). | ACCEPTED. `file_index.md`'s sole purpose is to be an accurate map, and the lead owns it. Recorded so the round's diff is fully accounted for. |

## Round cadence

Round 1: all three implementers work in parallel; test-runner runs the global gate once all three
report `READY_FOR_SIGNOFF`. Round 2 (only if the gate fails): the owner of the failing area fixes;
gate re-runs. Budget exhausted after round 2 → stop and report the failure trace to the user.
