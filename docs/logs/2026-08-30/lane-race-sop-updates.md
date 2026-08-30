# Lane-race hardening SOP staging (apply at merge time)

Written by impl-races-sonnet (Task 3, lane-race-arch-team). `memory.md` and
`unit_test.md` are gitignored, shared, live mutable state in the main
`Halcyon` worktree, possibly being edited concurrently by parallel sessions —
they do not exist in the `Halcyon-lane-race` worktree at all, so these edits
are staged here instead of applied directly (team-lead pre-authorized
deviation, same convention as `decode-lane-sop-updates.md`, 2026-08-30).

**The `G-NNN` number below and TC-380/381a/381b are all PROVISIONAL.**
Re-take the next free gotcha number by reading the live `memory.md` at merge
time; re-verify TC-380/381a/381b against the live `unit_test.md` register and
renumber if any collide (lessons-learned 2026-08-28, parallel sessions taking
the same next-free number).

Branch: `feat/lane-race-hardening`. Delivered tip at time of writing:
`eae7ebb` (Task 1 commit `0c0f152` + Task 2 commit `eae7ebb`, on top of three
pre-existing commits from a finished parallel workstream at `004938a`).

---

## Section 1 — new gotcha entry for `memory.md`

Insert as a new entry (verbatim, gotcha number to be resolved at merge —
substitute the real number for `G-NNN`; match the heading level and
formatting of the neighbouring entries):

```markdown
### G-NNN Check-then-act across an await inside a lane body (2026-08-30)

Both width>1 races found in `docs/logs/2026-08-30/lane-race-arch-verdict.md`
were the same shape: a check that gates expensive work, read before an await,
acted on after it.

**The rule:** any check that gates a decode or a publish must either be
re-validated after EVERY await between check and act, or the claim must be
taken synchronously with the check. **Entry existence is one of the terms** —
re-checking window membership and payload identity after an await, but not
"does an entry already exist", is what let the second publisher land.

Two enforcement points, deliberately not unified (the verdict's SEPARATE
ruling — a shared helper would own no state of its own and would have to
widen both owners' boundaries):

- `image_preload_controller.dart` `_ensurePayload` — the in-flight claim
  (`_loadingKeys.add`) is taken BEFORE the probe await, so check-and-claim is
  atomic. Its release lives on three exits: the expensive-route lane hand-off,
  the probe's catch, and the `finally`.
- `tier_two_registry.dart` `publishFullRes` — a synchronous first-writer-wins
  guard plus evict-before-overwrite. It sits in the one funnel every publisher
  passes through, so it also covers callers that do not exist yet. Caller-side
  `hasFullResEntryFor` checks stay: they save decode cost, the registry guard
  is the correctness backstop.

Still open (parking lot): `publishEncoded` overwrites `_keys[id]` the same way.
No `ui.Image` is held, so nothing leaks beyond ImageCache's own budget — the
same guard shape applies if it is ever promoted.
```

One-line status marker: none required — this is a standalone new entry, not a
supersession of an existing `AD-`/`G-` entry.

---

## Section 2 — `unit_test.md` matrix rows (TC-380 / TC-381a / TC-381b)

All green under `flutter test -j 1` on `Halcyon-lane-race` @ branch
`feat/lane-race-hardening`. Both artifact pairs below (red then green) are
committed in-branch as the evidence trail.

| TC | File:line | Case | Evidence |
|---|---|---|---|
| TC-380 | `test/services/image_pipeline/image_preload_controller_lane_race_test.dart:119` | two concurrent `_ensurePayload` entrants for the same id run exactly one source load; payload object identity stable (`identical`), decode lane width 2 | red: `docs/logs/2026-08-30/tc380-red.txt` (RC=1, `Expected: <1> Actual: <2>`); green: `docs/logs/2026-08-30/tc380-green.txt` (RC=0); full suite: `docs/logs/2026-08-30/fix-a-fullsuite.txt` (RC=0) |
| TC-381a | `test/services/image_pipeline/tier_two_publish_race_test.dart:44` | `publishFullRes` is first-writer-wins: loser's `ui.Image` disposed (`debugDisposed == true`), winner untouched, no double `notifyLoaded` | red: `docs/logs/2026-08-30/tc381-red.txt` (RC=1, `Expected: true Actual: <false>`); green: `docs/logs/2026-08-30/tc381-green.txt` (RC=0) |
| TC-381b | `test/services/image_pipeline/tier_two_publish_race_test.dart:98` | piggyback publish landing during a held upgrade decode is not displaced by that upgrade (lane width 2); registered provider identity stable, `registry.keyIds == {'a0'}` | red: `docs/logs/2026-08-30/tc381-red.txt` (RC=1); green: `docs/logs/2026-08-30/tc381-green.txt` (RC=0); targeted neighbours: `docs/logs/2026-08-30/fix-b-targeted.txt` (RC=0, includes `tier_two_registry_test.dart`, `tier_two_scheduler_test.dart`, `image_preload_controller_dual_window_tier2_test.dart`); full suite: `docs/logs/2026-08-30/fix-b-fullsuite.txt` (RC=0) |

| TC-384 | `test/services/image_pipeline/tier_two_publish_race_test.dart:185` | S-1 fix: inline chained upgrade and queued catch-up upgrade for the SAME id (different lane keys, `DecodeLane` cannot dedupe) do not both run the FFI decode at lane width 2; `TierTwoScheduler._upgradeFullRes` now takes a synchronous `_upgradesInFlight` claim before any await, released in `finally` | red: `docs/logs/2026-08-30/tc384-red.txt` (RC=1, `Expected: <1> Actual: <2>`, genuine double-decode, not a compile error); green: `docs/logs/2026-08-30/tc384-green.txt` (RC=0); targeted neighbours: `docs/logs/2026-08-30/tc384-targeted.txt` (RC=0, includes `tier_two_scheduler_test.dart`, `image_preload_controller_lane_race_test.dart`, `image_preload_controller_dual_window_tier2_test.dart`); 5x repeat: `docs/logs/2026-08-30/tc384-repeat-{1..5}.txt` (5/5 RC=0); full suite split by directory: `docs/logs/2026-08-30/s1-fullsuite-{models,perf,providers,services,views,main}.txt` (all RC=0); analyze: `docs/logs/2026-08-30/s1-analyze.txt` ("No issues found!", RC=0) |

S-1 (round-1 review) resolved: `tier_two_scheduler.dart` `_upgradeFullRes` third instance of check-then-act-across-await, fixed with the same shape as Fix A (`0c0f152`) -- a synchronous in-flight claim taken before the first await, not a shared helper with the other two enforcement points (each keeps its own state per the SEPARATE ruling in §1 above).

Note: *numbers reconciled against the SOP register on <date of merge>.*

---

## Section 3 — no `file_index.md` edit

Unlike the decode-lane precedent, this task renamed no files and added no
new source modules to track — `tier_two_registry.dart` and
`image_preload_controller.dart` already have entries; only their internals
changed. No `file_index.md` staging section needed.
