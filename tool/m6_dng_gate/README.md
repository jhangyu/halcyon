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
- `g3_sidebar_bench.dart` — port of
  `scripts/tmp/m6-r2-verify/g3_regress_dart_test.dart` (itself carried
  forward unmodified from `scripts/tmp/m6-r1-bench/g3second_dart_test.dart`).
  Measures the shipped sidebar pipeline end to end, including the P2.5b
  RAW-decode fallback (`decodeDngSized` → `readOrientation` →
  `jpegFromOrientedPixels`) for bare-CFA DNGs with no embedded preview at any
  size. **This is the verdict-bearing measurement.**
- `verdict_dng_extract.py` — encodes ruling P-13 as executable code.
- `run_gate.sh` — orchestrates a full gate run and writes a
  pre-registered, provenance-stamped result file.

**2026-08-24 note:** M7 Task 5 renamed the sidebar re-encode function
`pngFromOrientedPixels` → `jpegFromOrientedPixels` (PNG → JPEG re-encode).
`g3_sidebar_bench.dart` was updated to call the new name. This changes what
the RAW-decode-fallback branch of the sidebar bench measures: cache bytes
are now JPEG-encoded, not PNG-encoded. The measurement *method* (pipeline,
timing methodology) is unchanged; only the downstream API it calls was
renamed after the initial port.

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

## The P-13 rule (verbatim)

> A sample passes if its per-sample decode latency is under 75 ms
> absolutely, regardless of ratio; otherwise the 2.0x ratio clause against
> the recorded baseline applies.

The 75 ms floor is a literal constant (`FLOOR_MS` in
`verdict_dng_extract.py`), not a tunable/parameter — see the citation
comment beside it. No aggregation (median-of-medians, pass rate, etc.)
overrides a per-sample failure.

`verdict_dng_extract.py` carries the recorded reference baseline
(`BASELINE_MS`) as embedded data, transcribed verbatim from
`scripts/tmp/m6-r2-verify/p5-3-verify.txt` (the G'''' result-of-record for
the 33-sample canonical set, `scripts/tmp/m6-r1-bench/all_abs.txt`). Samples
without a recorded baseline are reported `SKIP`, not silently passed or
failed — the summary line's `skipped_samples` count makes that visible.

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
symbol under test and produced confident, wrong numbers (see
`memory.md`/`docs/logs/2026-08-23` provenance gotcha). If the vendored dylib
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

## Reproduction

Running against the canonical 33-sample set
(`scripts/tmp/m6-r1-bench/all_abs.txt`, i.e.
`local_data/photo_samples/DNG` + the JPEG sidecar samples) should reproduce
the recorded G'''' result: 33/33 PASS, with the 13 bare-CFA samples (RAW
decode fallback route) landing in the 31.6–63.1 ms band per
`scripts/tmp/m6-r2-verify/p5-3-verify.txt`.
