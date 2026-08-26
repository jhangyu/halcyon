## Measured performance

The photo-triage loop is look, judge, advance: the number that matters is time from a
keypress to a usable full-resolution image on screen, not raw decode throughput in the
abstract. Two very different costs hide behind that one number. Photos with an embedded
JPEG preview take the cheap path — extract and display the preview bytes, no RAW decode at
all. Photos with no usable embedded preview (bare-CFA DNGs, mostly from phones) fall
through to a full RAW decode via the sister project Ceyx, reached
through the `DngFullDecoder` seam
(`lib/services/image_pipeline/dng_decode_contract.dart`)
<!-- evidence: lib/services/image_pipeline/dng_decode_contract.dart -->. Tier-1 (a
window-resolution decode for immediate display) and tier-2 (the full-size decode, fired
after 250 ms of navigation quiet,
`lib/services/image_pipeline/image_preload_controller.dart:49`
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:49 -->) also cost
differently, so a number quoted without saying which tier, which path, and whether the
run was cold or warm is not a comparable number.

### What the recorded artifacts show

| Path / stage | Value | Conditions | Source |
|---|---|---|---|
| Full RAW decode, end-to-end, tier-2 on screen (4080×3056 bare-CFA DNG, 6-file sandboxed run) | cold 491–601 ms; warm 150–159 ms | macOS, **release** `.app` build, sandboxed, 2026-08-17, machine model not recorded | `docs/logs/2026-08-17/round-3b-reintegration-handover.md:27` <!-- evidence: docs/logs/2026-08-17/round-3b-reintegration-handover.md:27 --> |
| Same run, `rawDecode.ready` span, 9 events | 61–406 ms | Same conditions as above | `docs/logs/2026-08-17/round-3b-reintegration-handover.md:72` <!-- evidence: docs/logs/2026-08-17/round-3b-reintegration-handover.md:72 --> |
| Sidebar-thumbnail-purpose (200 px) decode, bare-CFA DNG, no-embedded-preview fallback route, 13-sample set | warm median 55.6–100.2 ms per sample | Runs under `flutter test` (`flutter_tester`, not a release app build), warm median of repeated in-process runs, target long edge 200 px | `tool/m6_dng_gate/verdict_dng_extract.py:41-73` <!-- evidence: tool/m6_dng_gate/verdict_dng_extract.py:41 -->, method in `tool/m6_dng_gate/g3_sidebar_bench.dart:42` <!-- evidence: tool/m6_dng_gate/g3_sidebar_bench.dart:42 --> |
| Same gate, DNG with usable embedded preview (fast path, no RAW decode), 12 samples | warm median 0.30–0.40 ms | Same harness as row above | `tool/m6_dng_gate/verdict_dng_extract.py:41-73` <!-- evidence: tool/m6_dng_gate/verdict_dng_extract.py:41 --> |
| Same gate, JPEG samples, 7 files | warm median 22.4–25.9 ms | Same harness as row above | `tool/m6_dng_gate/verdict_dng_extract.py:41-73` <!-- evidence: tool/m6_dng_gate/verdict_dng_extract.py:41 --> |
| Ceyx: end-to-end 24 MP DNG, lossless | ~177 ms | macOS (Metal), 2026-07-05, machine model not recorded | ceyx `README.md:403` <!-- evidence: /Users/jhangyu/project/ceyx/README.md:403 --> |
| Ceyx: end-to-end 24 MP DNG, lossy | ~105 ms | macOS (Metal), 2026-07-05, machine model not recorded | ceyx `README.md:404` <!-- evidence: /Users/jhangyu/project/ceyx/README.md:404 --> |
| Ceyx: cold first decode inside a GUI app, 6000×4000 lossless DNG | 291 ms | Apple M3 Ultra, macOS 15.6.1, release build, 2026-08-26, explicitly **cold** and not comparable to the warmed figures above | ceyx `README.md:410-413` <!-- evidence: /Users/jhangyu/project/ceyx/README.md:410 --> |
| Halcyon JPEG-preview switch latency (no RAW decode) | 2.8 ms (down from 127.5 ms pre-optimization) | Historical baseline, memory tag `image-switch-latency-round2-shipped`; superseded architecture, kept for the shape of the win | `docs/logs/2026-08-22/thumbnail-dart-first-plan.md:229` <!-- evidence: docs/logs/2026-08-22/thumbnail-dart-first-plan.md:229 --> |

The 4080×3056 sample above is a phone-camera bare-CFA DNG from this project's own sample
corpus (`local_data/photo_samples/`), not a studio/full-frame RAW; none of the artifacts
found record a sample resolution above 24 MP being measured through Halcyon's own app
shell (Ceyx's own bench uses 24 MP and 6000×4000 samples, but those numbers are Ceyx-only
runs, not Halcyon's app pipeline).

### Not measured

- No artifact records the current, still-shipping full RAW decode path (Ceyx's static-link
  build, post 2026-08-17) being re-benchmarked after the libjpeg sandbox blocker was lifted
  — the 61–406 ms / cold-491–601-warm-150–159 ms row above is the fix-verification run
  itself, and the same document flags it as needing a re-run once the decoder side's tree
  stopped moving (`docs/logs/2026-08-17/round-3b-reintegration-handover.md:29`)
  <!-- evidence: docs/logs/2026-08-17/round-3b-reintegration-handover.md:29 -->; no later
  artifact re-running it was found.
- No artifact records the machine model (chip, RAM) for any of the Halcyon-side rows in the
  table above. Ceyx's own README carries the same gap for its macOS figures except the one
  M3 Ultra data point.
- No artifact measures full-size decode latency for large-sensor (e.g. full-frame,
  40+ MP) RAW files running through Halcyon's own pipeline; Ceyx's README separately notes
  format-specific outliers (Fujifilm X-T5 40 MP RAF, Foveon X3F) that are not re-measured
  inside Halcyon.
- UI-driven switch-latency and memory (RSS) measurement is explicitly reserved for the
  project owner to run personally, not for agents
  (`lib/perf/perf_driver.dart:1-6`)
  <!-- evidence: lib/perf/perf_driver.dart:1 -->, so this section cannot report a current
  number for that even where the harness exists.
- Export-path timing (decode → resize → re-encode JPEG q90,
  `lib/services/library/photo_export_service.dart`) has no recorded artifact: **TBD (not
  measured)**.

### What number to quote

If a single figure is wanted, it is **about 300 ms for a cold, GPU-accelerated full RAW
decode**, and that figure comes from one recorded run rather than from a range chosen for
convenience: Ceyx's cold first decode of a 6000×4000 lossless DNG inside a GUI app, 291 ms
on an Apple M3 Ultra running macOS 15.6.1, release build, 2026-08-26.
<!-- evidence: /Users/jhangyu/project/ceyx/README.md:410 -->

Everything else in the table above is a different question, and the difference is worth
holding onto:

- **Warm decode is roughly half that.** The one full end-to-end Halcyon-side run that
  reached tier-2 paint measured 150–159 ms warm, and Ceyx's warmed matrix measured
  105–177 ms at 24 MP. A photographer moving back and forth across a handful of frames is
  in this regime, not the cold one.
- **Cold on the Halcyon side measured higher than 300 ms** — 491–601 ms in the 2026-08-17
  run, on an unrecorded machine. That run's own document flags it as needing a re-run once
  the decoder tree stopped moving, and no later re-run exists, so it is the weakest row in
  the table rather than a contradiction of the 300 ms figure.
- **Most files never decode at all.** A RAW carrying a usable embedded JPEG preview skips
  the decoder entirely and lands in single-digit milliseconds. The 300 ms figure describes
  the expensive path, which is the minority of files in a typical folder.

The honest summary: quote 300 ms as a cold full-decode figure for a named machine, quote
roughly 150 ms warm, and do not present either as a general benchmark — no artifact here
isolates cold from warm cleanly across a range of machines and sensor sizes.

### Reproducing these numbers

- `lib/perf/perf_driver.dart` and `lib/perf/perf_log.dart` are the app's own instrumentation:
  gated on the `HALCYON_PERF_DIR` environment variable (structurally a no-op otherwise,
  `lib/perf/perf_log.dart:38`) <!-- evidence: lib/perf/perf_log.dart:38 -->, it drives the
  app through photo switches and writes `PERF|<us>|<name>|key=value` lines, including a
  `rawDecode.ready|...|dur=` event for full RAW decodes
  (`lib/perf/perf_driver.dart:19-24`) <!-- evidence: lib/perf/perf_driver.dart:19 -->. Per
  the same file's header, this harness is reserved for the project owner to run personally,
  not for automated or agent-driven measurement.
- `tool/m6_dng_gate/` is a tracked, re-runnable gate for the sidebar-thumbnail decode path:
  `bash tool/m6_dng_gate/run_gate.sh <sample-dir> <out-file>` followed by
  `python3 tool/m6_dng_gate/verdict_dng_extract.py <out-file>`
  (`tool/m6_dng_gate/README.md:32-37`) <!-- evidence: tool/m6_dng_gate/README.md:32 -->. It
  requires a local sample corpus (`local_data/photo_samples/`, untracked) and the vendored
  Ceyx native dylib; it records the git commit, tree state, and a symbol check on the dylib
  before writing any number, specifically to prevent measuring a binary that does not
  contain the code under test (`tool/m6_dng_gate/README.md:69-86`)
  <!-- evidence: tool/m6_dng_gate/README.md:69 -->.
- `python3 native/tests/run_decode_matrix.py --repeat 3` reproduces Ceyx's own warmed
  matrix figures, run from the Ceyx repository
  (`/Users/jhangyu/project/ceyx/README.md:391-393`)
  <!-- evidence: /Users/jhangyu/project/ceyx/README.md:391 -->.
