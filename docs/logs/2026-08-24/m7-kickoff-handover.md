# M7 kickoff handover — M6 close → next session (2026-08-24)

> Written by `plan-writer-opus` of team `m6-r3-team` as M6's record closes. The next session starts as team lead for M7.
> M6 is DONE and its documents are CLOSED. Read them, never edit them.

## Startup sequence (do in order)

1. **Read the plan:** `docs/superpowers/plans/2026-08-24-m7-dng-contract-hardening.md` — header, the Governance section (settled, see below), Global Constraints, the seven tasks, the Dropped section, and the Decision Log. It is writing-plans format and each task is executable by a worker with no other context.
2. **Read the source of the work:** `scripts/tmp/m6-r2-verify/external-plan-gap-audit.md` — the audit the kept tasks come from. Note that three of its ten gaps were dropped by the user; the plan's Dropped section is authoritative over the audit's gap list.
3. **Read the standing rules:** `docs/logs/2026-08-24/m6-spec-contract.md` (C-1…C-8, §2.1 chosen shape, §4 U-11/U-12) and `docs/logs/2026-08-24/m6-feature-platform-matrix.md` §3 (rulings P-1…P-14; all resolved except P-2, the Linux `.so`).
4. `TaskList` — M6's tickets belong to team `m6-r3-team`. If `~/.claude/teams/m6-r3-team/config.json` still lists live members, follow `~/.claude/reference/team-shutdown-protocol.md` before spawning M7's team.
5. Spawn the M7 team per the task order below. **There is no user-decision gate to clear first** — scope is settled.

## Settled by the user, 2026-08-24 — do not re-open

- **Governance:** the per-feature preference cascade (ruling P-1 / term C-8) **stands**. The external design doc's five-platform *mandatory* set and its supersession claim over the M6 documents are **VOID**. Any future session finding those external docs should treat this verdict as authoritative, not the docs.
- **Undersized-candidate rule:** when no embedded candidate reaches the requested long edge, the file enters RAW decode rather than serving the largest undersized candidate. Delivered by Task 2.
- **Dropped:** committed binary fixtures (audit gap 6 — synthetic inputs are built in code instead); per-platform visible-render smoke records (gap 10 — user-run territory, declined); the iOS FFI port (gap 7 — superseded, see below).
- **Announced future direction, recorded verbatim:** *the `dng_decoder` library will later be upgraded into a general `raw_decoder` supporting ALL RAW formats.* Platform-port investment decisions belong to that successor effort, which is why the iOS port is not in M7.

## Task order

Independent, safe to run in parallel: **4** (Android `content://` + the destructive-navigation guard), **5** (sidebar PNG→JPEG), **6** (decoder packaging/ABI checker), **7** (promote the decode benchmark harness into tracked `tool/`).

Strictly serial, in this order, because all three edit `lib/services/dng_preview_extractor.dart` and two workers must never hold that file at once: **1** (synthetic-DNG test helper + big-endian coverage) → **2** (undersized-candidate rule + orientation clamp) → **3** (malformed-DNG parse-failure state).

Suggested first wave: Tasks 1, 4, 7 together. Task 4 carries the one genuinely destructive bug in the set. Task 7 lands the tracked gate harness that Task 2 wants as its measurement tool — if Task 7 has not landed when Task 2 needs it, Task 2 falls back to the `scripts/tmp/m6-r1-bench/` harness with provenance recorded, which the plan already permits.

Two couplings worth watching: Task 1 produces the `test/support/synthetic_dng.dart` helper that Tasks 2 and 3 both consume, so Task 1 slipping blocks the whole chain; and Tasks 2 and 5 both change sidebar behaviour from different files, so whichever lands second re-runs the other's suite before committing.

## Standing rules that carry forward (enforce, do not re-derive)

- **UI verification is USER-RUN ONLY.** Agents never drive the UI, screenshot the app, automate key or drop interactions, or assert on rendered pixels. Reconfirmed this session for drop behaviour and key-interaction probes.
- **No UI latency or memory measurement by agents** (C-6). Headless decode benchmarks only.
- **No committed binary fixtures.** Synthetic test inputs are built in code at test time and written to a temp directory.
- **C-3: no platform branches in `lib/`.** Enumerated exceptions unchanged: `perf_driver.dart`'s env reads and the one F-19 reveal site in `status_line.dart`.
- **RC self-capture.** Exit codes are captured as `RC=$?` inside the artifact, immediately after the command. Never `${PIPESTATUS[0]}`, never a pipe- or tee-derived code, never the harness's completion notification — the notification has lied in both directions.
- **Red before green.** A test nobody watched fail is not evidence.
- **Prove the binary contains the code under test** before any measurement — content marker or exported symbol, never mtime. A past round measured a dylib lacking the symbol under test and produced confident wrong numbers.
- **75 ms absolute decode floor** (ruling P-13): any per-sample decode under 75 ms passes outright regardless of the 2.0× ratio clause. A fixed constant, not a tunable.
- **No full-tree git operations** (`stash` / `reset` / `checkout --` / `clean`). Stage explicitly by filename; other workers have uncommitted files in the tree.
- **The M6 record is closed.** `docs/logs/2026-08-24/m6-*.md` are read-only. New decisions go in the M7 plan's Decision Log; architecture goes in `memory.md` as AD-NNN / G-NNN.
- **Parking-lot discipline** (C-7): findings during a round do not become that round's acceptance criteria. Round budget 3.

## State at handover

- M6 R2 closed at `bcedafc`: suite 280/280, `flutter analyze` 0 issues, macOS + Android release builds green, C-3 grep guards clean, G″″ regression gate 33/33 PASS. Every contract term C-1…C-8 satisfied or closed by ruling.
- Only M6 open item: **P-2**, the Linux `.so` for the FFI decoder. Unchanged in status by M7; Task 6's manifest carries it as `expected: false` so it flips with one boolean.
- Windows artefacts remain trust-on-first-use — code landed in M6, no real Windows host has run them. Task 6 will report `symbol=skipped` for Windows on a macOS host; that is correct behaviour, not a pass.
- Canonical sample verified present on this host: `local_data/photo_samples/DNG/2024-07-03-18-52-26.dng`. `local_data/` is untracked, so tasks reading the photo corpus stop and report if it is gone rather than substituting.
- `tool/` and `test/support/` do not exist yet — Tasks 7 and 1 create them.

## Parking-lot carried in from M6

- P-2: Linux `.so` build (F-07/F-09 sit on the macOS+Windows+Android tier until it exists).
- Idle `claude-swarm` tmux servers from past sessions — fail-closed, 48h auto-clean hook.
- Still parked: the Android/iOS end-to-end Open With flow. Task 4 delivers a readable file; folder scanning on mobile (matrix F-02) remains unaddressed.

## Verification commands (run to confirm this handover's claims)

```bash
git log --oneline -5                                  # M6 tip bcedafc, then M7's docs commit
flutter analyze                                       # 0 issues
flutter test -j 1                                     # All tests passed!, 280 executed
ls docs/superpowers/plans/2026-08-24-m7-dng-contract-hardening.md   # the plan
ls local_data/photo_samples/DNG/2024-07-03-18-52-26.dng             # canonical sample
grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/ | grep -v perf_driver.dart | grep -v status_line.dart   # no rows
```
