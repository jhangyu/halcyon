# Native encoder comparative benchmark — conclusion (Phase 13 Task 0b)

Scratch-lane CLI-process timing (Homebrew `cjpeg`/`cwebp`), fixture: full-res
oriented RGB (alpha dropped) from `local_data/photo_samples/DNG/IMG_20251112_092839.dng`,
4080x3056, dumped once by `scripts/tmp/reencode_bench.dart` to
`scripts/tmp/reencode_fixture.ppm` (37,405,457 bytes, P6 PPM). Both encoders run
at q80 (matching the shipped `kReencodeJpegQuality`), 3 reps each, in the same
run. Raw output and versions: `docs/logs/2026-08-30/native-encode-bench.txt`
(RC=0 captured inline).

Versions: `libjpeg-turbo 3.2.0` (cjpeg), `libwebp 1.6.0` (cwebp).

## Medians

| encoder | bytes | ms (raw reps) | median ms |
|---|---|---|---|
| cjpeg (libjpeg-turbo) q80 | 1,986,685 | 82, 58, 62 | **62** |
| cwebp (libwebp) q80 | 1,651,630 | 3103, 2876, 2805 | **2876** |

Both are CLI-process timings (process spawn + PPM file read included) — an
**upper bound** on what an in-process FFI binding would cost; the real number
will be lower for both, but the *relative* gap between them is a fair signal.

## Comparison against the pure-Dart baseline (Task 0, `reencode-bench.txt`)

`package:image`'s `encodeJpg` (pure Dart, in-isolate, no process-spawn
overhead) measured **4102 ms** median at q80 on the same fixture (Task 0's
committed number — not re-run here).

- **cjpeg is ~66x faster than the pure-Dart encoder** (62 ms vs 4102 ms), and
  comfortably clears the 500 ms gate even counting process-spawn overhead.
- **cwebp is ~1.4x faster than the pure-Dart encoder** (2876 ms vs 4102 ms),
  but still ~5.75x OVER the 500 ms gate on CLI timing alone — it would need a
  very large in-process speedup to clear the threshold, and there is no
  evidence here that the gap is process-spawn overhead rather than genuine
  algorithmic cost (libwebp's encoder does more analysis passes than baseline
  libjpeg at comparable quality settings, which is a known general property,
  not just an artifact of this fixture).
- Byte size: cwebp's output is ~17% smaller than cjpeg's (1.65 MiB vs 1.99 MiB)
  at nominal q80 — WebP's density advantage is real, but it is not close to
  enough to offset a ~46x slower encode on this measurement.

## Recommendation

**PROCEED with libjpeg-turbo (cjpeg-equivalent FFI binding) as the encoder
that goes first**, per the user ruling that ceyx will carry both but the
faster one leads. libjpeg-turbo clears the Task 0 500 ms gate by a wide margin
even under CLI-timing overhead; libwebp does not, on this measurement, and its
size advantage does not compensate for the latency it would add back to the
selected-item worst case that motivated the STOP verdict in the first place.

This is a scratch-lane recommendation only — it does not implement anything.
The next step (adding a libjpeg-turbo encode path to `ceyx` and wiring it as
`PayloadEncoder` in Task 1) requires an explicit go-ahead; this file is input
to that decision, not the decision itself.
