# M3 Round 1 — Sonnet Takeover Handover

> **Created**: 2026-08-23
> **Worktree**: `/Users/jhangyu/project/halcyon-m3`
> **Branch**: `m3-cache`
> **Committed tip**: `867b6ee`
> **Status**: **STOPPED / PRESERVED. No M3 implementation, tests, commits, reverts, resets, stashes, or checkout operations are authorized until the Sonnet seam review returns and the orchestrator gives a new explicit order.**
>
> **Model disposition**: The user observed that the round's Opus members were not responding reliably. The Opus implementer and Opus reviewers are no longer trusted for forward work in this round. `m3-seam-review-sonnet` is the replacement, read-only reviewer. It must decide the orientation seam before any further action.

---

## 1. User decisions — authority

Read `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` before acting. Its D1–D6 are frozen. The following clarifications from the user are binding:

```text
ALL file types (JPG, preview-bearing DNG, no-preview DNG):
  one type-blind −3..+5 payload retention window
  one byteCost-only cache budget and eviction rule
  no file-type-specific retention policy

EVERY item:
  content probe FIRST
  probe decides execution only:
    JPEG / embedded JPEG -> parallel retrieval/decode
    no embedded JPEG -> sequential RAW decode after unchanged 250 ms debounce

±1:
  expensive RAW STARTUP eligibility only
  never a retention boundary

Sidebar:
  one type-blind 20 + visible + 20 thumbnail strategy
```

The old `scripts/tmp/dng_nav_probe_test.dart` stays byte-untouched. Its required SHA256 is:

```text
05565d3347f6e7e3746a8e2702c45ff854a52e1a80bb181c581f8eee4051f77f
```

RSS acceptance is blocked until the user supplies **at least nine real no-preview DNG samples**. Do not manufacture copies.

---

## 2. Preserved repository state

### Worktrees

```text
main: /Users/jhangyu/project/Halcyon @ dd296ba
current M3: /Users/jhangyu/project/halcyon-m3 @ 867b6ee (m3-cache)
historical test lane: /Users/jhangyu/project/halcyon-m3-red @ 3e51bc4 (m3-amend3-red)
```

### Current M3 uncommitted tracked WIP — DO NOT MODIFY

```text
M lib/services/image_preload_controller.dart
M lib/services/photo_source.dart
```

Expected scratch/untracked entries:

```text
scripts/tmp/dng_nav_probe_test.dart
scripts/tmp/m3-handover-preserve.md
scripts/tmp/m3-step5-test-diff.txt
scripts/tmp/verify/
```

The previous invalid targeted `+33` run is behavioral reference only, **not acceptance evidence**. It ran after a scope breach and must never be cited for acceptance.

### Commit lineage

```text
193bf12  payload cache + RawPixelsImage (additive)
c272f8e  content cost probe, PhotoSource selector, window-sized RAW pixels (additive)
0e6407e  unified image payload pipeline (unsigned preserved WIP origin)
ebc59dc  M3 hold handover
1ba1bee  correction: prior battery had analyze failure
be9e05e  Amendment 3: user correction recorded
cb2175f  durable WIP checkpoint
867b6ee  frozen Amendment-3 test-only commits
```

`0e6407e` and all later preserved M3 work are **not accepted**. They need fresh review and new hash-bound verification.

---

## 3. Process failures and exclusions

There were three breaches in M3 round 1:

1. Step 5 began/committed without the required mid-point audit and after a HOLD order.
2. Amendment-3 production code was changed before the required RED evidence existed.
3. Current targeted-green lane changed `photo_source.dart` while approval allowed frozen test blobs plus a controller-only repair.

Consequences:

- No prior full battery, targeted battery, or old analyze output is acceptance evidence.
- `bggsobn3g` is explicitly invalid. It printed test success but had an analyzer failure in its authoritative correction.
- Test count claims `N=31` and `N=25` are withdrawn. Re-establish from the final test set before any future full suite.
- T-B/T-C evidence is not complete until a fresh authorized plan resolves it. T-B uses pre-M3 hash-bound baseline + fresh comparison; it must not mutate production debounce. T-C can use an isolated copied mutation lane with hash restoration only.

---

## 4. Valid historical evidence

Historical lane used actual production predecessor `0e6407e` with frozen test-only commit `3e51bc4` / test tip `3e51bc4`.

Valid historical artifact:

```text
/Users/jhangyu/project/halcyon-m3-red/tmp/verify/amend3-historical-complete-with-fixtures.log
```

It contains substantive failures of the predecessor:

```text
selected real no-preview DNG: expected bridge calls 0, actual 1
+1 real no-preview DNG: expected bridge calls 0, actual 1
three RAW decodes: expected max concurrency 1, actual 3
```

It also establishes historical green controls:

```text
real preview-bearing DNG cheap control
P1 exact 5, repaired P2, P3, expanded P4
uniform -3 survive / -4 evict symmetry
cheap overlap
```

Frozen test blobs used for the historical gate:

```text
test/dng_nav_probe_m3_test.dart
  SHA256 be3a595d6cc49c48d9f4bd29e91ecf5827261c50ae6b5d1c18e911e8b47d2341
  git blob 0bfe042db80b204029ae85d21b2502898814184c

test/image_preload_controller_m3_amend3_test.dart
  SHA256 fcdd564ea168039b68ae63a3497d784a9824d5fb141885777bfc3fb3e44c019c
  git blob bec1aba038ebbd9824e8c3e96ee616477c515a27
```

Before any current-lane green run, a future reviewer must verify these test bytes remain identical.

---

## 5. Current seam under Sonnet review

Uncommitted `photo_source.dart` adds:

```dart
static Future<int?> probeOrientation(String path) =>
    DngPreviewExtractor.readOrientation(path);
```

Uncommitted controller WIP:

- classifies every item in the common retention window before loading;
- obtains orientation for expensive probe results;
- makes tier-two expensive work sequential by replacing fan-out with await;
- keeps `±1` as startup eligibility only.

This seam is authorized by the user only **conditionally**. The Sonnet reviewer must issue exactly one verdict:

```text
CONFIRMED-SEAM
REFUTED-SEAM
BLOCKED
```

Required review questions:

1. Can a single bounded `PhotoSource.probe` return both cost and orientation from one IFD walk, instead of `probe()` then `probeOrientation()`?
2. Does the two-call shape cause a double TIFF/IFD walk or violate the ≤300 KB probe budget?
3. Does it preserve at-most-one `ImageBytesLoader`/bridge call per item on selected/+1 real no-preview DNG and fake/unreadable paths?
4. Does it preserve common `−3..+5` retention, 250 ms debounce, sequential RAW, and cheap parallel work?
5. Is `photo_source.dart` otherwise scope-clean?

No production modification is allowed based on an implementer claim. The Sonnet verdict must be reviewed by the orchestrator first.

---

## 6. Next actions

1. Await `m3-seam-review-sonnet` verdict. Do not use or await Opus reviewer conclusions.
2. If **REFUTED-SEAM**: preserve the WIP unchanged; make no repair until the orchestrator/user chooses a single-probe `ProbeResult { cost, orientation }` design or another explicit alternative.
3. If **CONFIRMED-SEAM**: still do not run full suite. First obtain an independent review of the final diff, calculate and pre-register the final test count, then run a new hash-bound analyze + targeted battery. Full battery only by subsequent explicit authority.
4. Keep RSS last and blocked on user samples (≥9 real no-preview DNGs).
5. Any future work must use Sonnet or another user-approved replacement, not the currently unreliable Opus members.

---

## 7. Verification status table

| Area | State | Evidence status |
|---|---|---|
| D4 type-blind cache static shape | reportedly present | needs fresh final review/grep |
| common `−3..+5` retention | present in preserved controller WIP | needs fresh executable test/battery |
| probe-first selected/+1 | predecessor RED captured | current repair unaccepted |
| sequential no-preview RAW | predecessor RED captured | current repair unaccepted |
| cheap parallel | historical control green | current repair unaccepted |
| P1/P2/P3/P4 translated table | historical tests present | current run invalid; needs authorized fresh run |
| Step 3b permanent miss / no repeated calls | static/targeted evidence exists | needs authorized fresh run |
| D2 JPEG controls | no accepted final evidence | must be re-run in authorized battery |
| analyzer | conflicting old artifacts | must be re-run fresh, hash-bound |
| full suite / test count | no accepted result | must be re-established |
| RSS <350 MB | blocked | waiting on real samples |

---

## 8. Red lines

```text
No git reset, checkout --, stash, clean, force-push, or destructive recovery.
No use of old invalid targeted/full batteries as acceptance evidence.
No current-lane changes until Sonnet verdict and orchestrator authorization.
No full suite until test count is mechanically inventoried and pre-registered.
No synthetic copies for RSS.
No type-based cache retention or sidebar policy.
```
