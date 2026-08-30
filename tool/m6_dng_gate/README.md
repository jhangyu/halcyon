# `tool/m6_dng_gate` — tracked DNG decode gate

Promotes the M6 decode-benchmark harness from gitignored `scripts/tmp/` into
tracked `tool/` (M7 Task 7, audit gap 9: "the decode gate governs every
performance decision in this project, and it currently exists only under
gitignored `scripts/tmp/` — not re-runnable from a clean checkout"). The
method is ported **unchanged**:

- `g1_extract_bench.dart` — port of `scripts/tmp/m6-r1-bench/g1_dart.dart`.
  Measures `DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path)`
  directly (informational; not verdict-bearing here since this tool ships
  with no native-side comparison binary).
- `verdict_dng_extract.py` — RETIRED 2026-08-30 (AD-039); now prints a
  retirement notice and exits 0. See below.
- `run_gate.sh` — orchestrates a full gate run and writes a
  pre-registered, provenance-stamped result file. Its former Stage 4/5 (the
  G3 sidebar bench invocation) is likewise retired; see the comment at that
  spot in the script.

**2026-08-30 note (AD-039):** the sidebar RAW-decode fallback (`decodeDngSized`
→ `readOrientation` → …) used to re-encode every produced thumbnail as JPEG
via a `jpegFromOrientedPixels` step; it now stores the oriented, capped pixels
directly (no re-encode) so the sidebar tile builds a `RawPixelsImage`. The
former `g3_sidebar_bench.dart` timed that now-removed re-encode step end to
end and was deleted rather than repaired (user ruling) — there is nothing
left in the pixel path that matches its recorded baseline's semantics. Do not
resurrect a G3-style bench against the pixel path without recording a new
baseline first.

## Invocation

```bash
bash tool/m6_dng_gate/run_gate.sh <sample-dir> <out-file>
python3 tool/m6_dng_gate/verdict_dng_extract.py <out-file>
```

Example:

```bash
bash tool/m6_dng_gate/run_gate.sh local_data/photo_samples/DNG /tmp/m7-gate.txt
python3 tool/m6_dng_gate/verdict_dng_extract.py /tmp/m7-gate.txt; echo "RC=$?"
```

`run_gate.sh` fails loudly (`exit 1`) if `<sample-dir>` does not exist or
contains no `.dng`/`.jpg`/`.jpeg` files — it never falls back to synthetic
input. `local_data/photo_samples/` is untracked; if it is absent on your
host, the gate cannot run and says so.

## The P-13 rule — RETIRED 2026-08-30 (AD-039)

> A sample passes if its per-sample decode latency is under 75 ms
> absolutely, regardless of ratio; otherwise the 2.0x ratio clause against
> the recorded baseline applies.

This rule and its `FLOOR_MS`/`BASELINE_MS` constants applied to the deleted
G3 sidebar bench and no longer run. The literal rule text and the recorded
baseline table survive in git history (see any commit before this one that
touches `verdict_dng_extract.py`) for anyone recording a new baseline
against the pixel path.

## Provenance (never mtime)

`run_gate.sh` writes, before any number exists:

1. `git rev-parse HEAD` and `git status --porcelain` — which commit and
   tree state produced the numbers.
2. `nm -gU` on the vendored native dylib
   (`../ceyx/plugin/macos/Libraries/libdng_decoder_native.dylib`
   by default, override with `DNG_DYLIB=<path>`), grepped for
   `dng_decode_and_process_sized` — the symbol the sidebar RAW fallback
   depends on — plus `shasum -a 256` of that file.

This exists because a past round measured a dylib that did not contain the
symbol under test and produced confident, wrong numbers (see the architecture
decision log's provenance gotcha, also documented in `docs/logs/2026-08-23`).
If the vendored dylib
is absent on the current host, `run_gate.sh` records `DYLIB_MISSING` and
reports the symbol check as skipped — it never silently treats that as a
pass.

## Pre-registration

`run_gate.sh` writes the decision rule and the intended verdict machinery
into the result file's header, above the `RESULTS` banner, before any
measurement runs. Re-running with different parameters until a run passes
is forbidden; a failing run stays in the artifact rather than being
discarded and re-attempted.

## Method-stability note

Per Task 7's constraint, the harness's method was not redesigned during the
port. If a bug is found in the original `scripts/tmp/` harness, it is
reported to the team lead rather than silently fixed here — silently fixing
it inside the port would make the reproduction check against the recorded
G'''' result meaningless.

## Reproduction — RETIRED 2026-08-30 (AD-039)

The G'''' 33-sample reproduction this section used to describe was the G3
sidebar bench's own result and no longer applies (see the retirement notes
above). `g1_extract_bench.dart` remains runnable and informational; it has
no PASS/FAIL verdict of its own.
