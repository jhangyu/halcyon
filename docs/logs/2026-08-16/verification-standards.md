# Verification artefact standard (Halcyon)

> Written 2026-08-16, round 3a. Applies to any artefact offered as evidence that
> something works or is fast enough.

Four times in one round the verification infrastructure produced an artefact
that was complete-looking and empty, with nothing failing. That is the failure
mode this page exists to stop. The shape is always the same:

**the artefact exists, the format is right, the content is empty or
non-comparable, and nothing screams.**

## 1. What an artefact must carry

An artefact that does not carry all five is not evidence, regardless of what
its numbers say:

1. **Sample counts per class**, not just overall. "n=84 nativeTotal" is a
   sample count; "the run completed" is not.
2. **Build mode, proved by a captured line**, not asserted in prose. Keep the
   `flutter run` / `flutter build` stdout: `Launching ... in profile mode` or
   `Built build/macos/Build/Products/Profile/Halcyon.app`. Numbers from
   different modes are not comparable — round-3a's "8x p95 regression" was
   Debug vs Profile and nothing else.
3. **HEAD hash and the dirty-file list at the time of the run.** A number
   without a hash cannot be attributed to a change.
4. **The validity gate's verdict**, pasted in. See §2.
5. **The exact command line**, including env vars, so it can be re-run.

## 2. The perf validity gate

```
scripts/tmp/perf/analyze_run.sh <run.log> <stdout-capture.log> \
    [--build-log <build.log>] [--expect-mode profile]
```

This is the supported way to turn a perf log into numbers. It runs
`scripts/tmp/perf/validate_run.py` first and **refuses to invoke
`parse_r2.py` on a rejected log**. `parse_r2.py` itself is never modified: it
reproduces round-2's published baselines exactly and is the only reason
cross-round comparison is possible.

The gate rejects, with exit 1 and a stable reason code, a log that:

| code | condition |
|---|---|
| `E_FOLDER_EMPTY` / `E_DRIVER_ABORT` | `folder.load.end items=0`, or any `driver.abort` |
| `E_PASS_ZERO_RESOLVED` | any pass with switches but zero `image.resolved` **in that pass** |
| `E_UNRESOLVED_SWITCH` | a `switch.begin` that never got a matching resolve (parse_r2's VOID condition, promoted to a hard fail) |
| `E_NO_TIER2_RESOLVE` | no `tier=2` resolve anywhere — the tier2 classes would be empty while the report still renders |
| `E_SWITCH_TIMEOUT` | any `switch.timeout` / `burst.timeout` |
| `E_FIXED_TIMEOUT_SPACING` | ≥3 consecutive switches spaced at a near-constant interval far above the configured pace (the 15.005s shape) |
| `E_MISSING_EVENT_CLASS` / `E_MISSING_NATIVE` | an event class `parse_r2.py` needs is absent |
| `E_RESOLVED_ID_NOT_POSITIONAL` / `E_RESOLVED_FIELD_MISSING` | `image.resolved` shape drifted from the contract |
| `E_NO_DRIVER_DONE` | no `driver.done` — the run was truncated |
| `E_SAMPLE_FLOOR` | fewer than `--min-switches` (default 20) switches |
| `E_NO_BUILD_MODE_PROOF` / `E_BUILD_MODE_MIXED` / `E_BUILD_MODE_MISMATCH` | build mode unprovable, inconsistent, or not the expected one |

Non-blocking: settle-wait timeouts between passes (`pass.*.reset.timeout`,
`rapid.final.timeout`) are reported but do not void a run — round-2's own
published baseline logs contain them.

The gate is itself proved to discriminate:
`scripts/tmp/perf/validate_run_selftest.py` takes the round-2 baseline log,
injects one defect at a time, and asserts each is rejected with the right code
(`tmp/verify/r3/gate_selftest.txt`, 15 mutants, 0 blind spots).

## 3. The four failure shapes, as worked examples

**A. The empty directory.** A relative `HALCYON_PERF_DIR` pointed at nothing.
The log said `folder.load.end|items=0` then `driver.abort`, and the run ended
normally. Zero samples read as a clean pass.
→ caught by `E_FOLDER_EMPTY` / `E_DRIVER_ABORT`.
→ note the sandbox rule: **both** `HALCYON_PERF_DIR` and `HALCYON_PERF_OUT`
must be relative paths inside the app container.

**B. The probe that tested a copy.** The A5 probe validated a paste of the
extractor rather than the shipped file, so drift would have been invisible.
→ structural fix: the test compiles the shipped source. Never a copy.
`scripts/tmp/run_dng_extractor_tests.sh` passes
`macos/Runner/DngPreviewExtractor.swift` to `swiftc` directly; mutation testing
passes a mutated **temp copy** as an argument so the tree is never edited.

**C. The build-mode mismatch.** Round-3a numbers (Debug) versus round-2
baselines (Profile) produced a phantom 8x p95 regression.
→ caught by `E_BUILD_MODE_MISMATCH`; the mode must be provable from captured
output, not from memory.

**D. The dedupe that emptied a pass.** The `image.resolved` dedupe set was
process-global instead of per-switch, so the second pass emitted zero events.
The driver then timed out 15s per item and produced six minutes of log that
still looked normal.
→ caught by `E_PASS_ZERO_RESOLVED`, `E_SWITCH_TIMEOUT` and
`E_FIXED_TIMEOUT_SPACING` (all three fire on the real artefact,
`tmp/verify/r3/perf_dng_profile.stdout.VOID.log`).

## 4. Tests: the only question that matters

**If the logic breaks, does something scream?** A test that has never been
shown failing is not evidence. Before offering a test as coverage, break the
thing it covers and show the red.

- Extractor: `scripts/tmp/mutation_dng_extractor.sh` runs 9 mutations against
  out-of-tree copies and requires every one to be killed
  (`tmp/verify/r3/mutation_dng_extractor.txt`).
- Perf gate: `scripts/tmp/perf/validate_run_selftest.py`, as above.

Corollaries learned the hard way:

- **Never skip.** A test that skips when a tool or sample is missing reports
  green having checked nothing. Fail instead
  (`test/dng_extractor_swift_test.dart` fails, loudly, if `swiftc` is absent).
- **Assert the count.** A suite that exits 0 having asserted nothing looks
  identical to one that passed. The Dart wrapper requires the Swift suite to
  report `ALL PASS` and ≥20 checks.
- **When the real material cannot make a guard observable, synthesize
  material that can, or say plainly that it cannot be tested.** Do not report
  an untestable guard as covered. See
  `scripts/tmp/make_synth_dng.py` for fixtures built exactly for this.
- **Never mutate shipped source in the shared tree.** Teammates are working in
  it, and an in-tree weakening of a security or correctness check reaches them
  as an apparently-intentional change. Mutate a copy.

## 5. Minimum artefact header

Paste this at the top of any verification artefact:

```
command:    HALCYON_PERF_DIR=perf_dng ... flutter run --profile -d macos
build mode: profile   (evidence: tmp/verify/r3/build_profile.log:10)
HEAD:       3cbc5ff   dirty: lib/perf/perf_log.dart, macos/Runner/AppDelegate.swift
gate:       ACCEPT    (scripts/tmp/perf/analyze_run.sh, 0 blocking problems)
samples:    switch.begin n=40, nativeTotal n=84
```
