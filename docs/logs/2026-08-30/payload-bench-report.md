# Payload bench report — D-2/D-5 (shared-payload-cache-plan.md)

Investigator: bench-investigator-opus. Date: 2026-08-30. Scratch lane only; nothing in `lib/` or `test/` was modified.

Library measured (read-only): `/Volumes/EVO_4TII/2026.08 新潟/DNG/2026/2026-08-09` — 125 Sony A7M5 (ILCE-7M5) `.ARW`, 16.9–36.5 MB each.

Pre-registered interpretation rules stand as written in `scripts/tmp/payload_size_bench.dart` (R1 = sum of the 60 LARGEST payloads vs 384 MiB, also reported vs 304/224 MiB; R2 FASTER iff median sized/full ratio <= 0.70; R4 no re-runs with changed parameters). One pre-registration premise was **falsified by measurement** and is corrected in §2 — the correction is documented, not quietly applied.

---

## 1. Verdict summary

| Scenario | Top-60 sum | vs 384 MiB | vs 304 MiB | vs 224 MiB |
|---|---|---|---|---|
| **PRODUCTION payload** (q80 full-res JPEG, §2) | **240.3 MiB** | **FIT** (62.6%) | **FIT** (79.0%) | EXCEED (107.3%) |
| Embedded `JpgFromRaw` (pre-registration's assumed payload — NOT what runs) | 402.1 MiB | EXCEED (104.7%) | EXCEED (132.3%) | EXCEED (179.5%) |
| RAW file bytes (worst case, hypothetical) | 1736.8 MiB | EXCEED (452%) | EXCEED (571%) | EXCEED (775%) |
| `PreviewImage` (small IFD0 preview, reference only) | 29.3 MiB | FIT | FIT | FIT |

**R1 answer (production column): YES — 60 full-size payloads fit the 384 MiB high rung, and also fit the 304 MiB mid rung; they do NOT fit the 224 MiB floor.**

**R2: NOT FASTER.** ceyx `maxDim: 200` sized decode median 457 ms vs full sensor decode median 505.5 ms; median per-file ratio **0.916** (rule: <= 0.70 to count as faster). n = 20 paired runs, order alternated.

Raw artifacts: `tmp/verify/payload-bench.clean.csv` (125 rows), `tmp/verify/r1-final.txt`, `tmp/verify/r1-compute.txt`, `tmp/verify/r2-bench.csv`, `tmp/verify/r2-result.txt`. Scripts: `scripts/tmp/arw_payload_bench.dart`, `scripts/tmp/arw_r2_bench.dart`, `scripts/tmp/arw_prod_route_probe.dart`.

---

## 2. Which column is the production payload (anomaly resolved)

**The `-202 kRawErrProbeFailed` result was an investigation artifact, not production behaviour.** Running the exact production chain headless succeeds on these files:

```
$ DNG_NATIVE_BUILD_DIR=/Users/jhangyu/project/ceyx/plugin/macos/Libraries \
  dart run scripts/tmp/arw_prod_route_probe.dart <file> sized
[Contract] RawGpuPipeline layout=bayer2x2 size=7040x4688 ... backend=libraw_native -> PASS
SIZED200 OK 200x133 549ms
FULL OK 7028x4688 542ms
```

125/125 files decoded with zero errors during the payload bench. ceyx's raw route does support A7M5: `.arw` is in `kRawExtensions` (`ceyx/plugin/lib/src/raw_route.dart:20`) and resolves to `DecodeRoute.raw` (`:67-72`), backed by libraw.

Production route for these ARW, traced:

1. `dart_image_loader.dart:176-184` — `probeEmbeddedJpeg` returns no bytes (see §3), so no `NativeImageBytes`.
2. `dart_image_loader.dart:218-242` — `.arw` is `isDecodablePath` (derived from ceyx `kSupportedDecodeExtensions`, `supported_photo_formats.dart:3,11`), so the loader emits `NativeImageNeedsRawDecode`.
3. `full_decoder_dispatch.dart` RAW arm → `dng_decode_service.dart:12-29` `decodeDngFull` → ceyx `DngDecoderService.decodeOnWorker` → full-sensor RGBA **7028×4688** (131.8 MB of pixels).
4. `photo_source.dart:190-221` — the decode result is re-encoded **before the payload exists**: `reencodePayload(encoder: …, fullRes: …)` at `:217-221`, quality `kReencodeJpegQuality = 80` (`payload_reencoder.dart:26`), encoder = `_encodeJpegNative` (`image_preload_controller.dart:34-45`, ceyx `CeyxEncodeService().encodeJpegNative`).
5. The cached `EncodedPayload.bytes` is therefore **a q80 full-resolution JPEG produced from the RAW decode** — not the camera's embedded JPEG, not the raw file bytes.

So the production payload column is row 1 of the table. Measured distribution over 125 files: min 0.92 MiB, median 2.38 MiB, max 6.49 MiB; whole-folder resident total if every item were retained = 348.8 MiB. Timings: decode median 517 ms (486–597), native q80 encode median 78 ms (67–100).

**Correction to the pre-registration.** `scripts/tmp/payload_size_bench.dart`'s header asserted "in production these files NEVER hit the ceyx sensor decode — the payload is the embedded JPEG". That premise is false in both halves: the sensor decode is exactly what runs, and the embedded JPEG is never reached. The R1 *rule* (60 largest, adversarial) is unchanged and was applied to the corrected payload definition; the embedded-JPEG and raw-bytes numbers are reported above so the change of premise cannot hide behind a nicer verdict. Note the direction: the correction made the verdict *more* favourable (402.1 → 240.3 MiB), which is precisely why it is spelled out.

## 3. Why `DngEmbeddedJpegExtractor` misses Sony's full-res JPEG (finding only — NOT fixed)

exiftool on `2026-08-09-09-26-24.ARW`:

```
[IFD0]   Compression 6      PreviewImageStart 200866   PreviewImageLength 326560
[SubIFD] Compression 32766  StripOffsets 4395008  DefaultCropSize 7008 4672
[IFD1]   Compression 6
[IFD2]   Compression 7  PhotometricInterpretation 6  ImageWidth 7008  ImageHeight 4672
         JpgFromRawStart 528384   JpgFromRawLength 3863142
```

Three independent reasons the walker finds zero candidates:

- **The IFD chain is never followed.** `dng_embedded_jpeg_extractor.dart:610-621` builds `candidateIFDs` from IFD0 plus the SubIFDs listed in tag `0x014A` only. Sony's full-res JPEG lives in **IFD2**, reachable only via the TIFF `nextIFD` pointer chain (IFD0 → IFD1 → IFD2), which the reader never traverses in the candidate scan.
- **Only strip-based candidates are recognised.** The candidate loop requires `StripOffsets` `0x0111` and `StripByteCounts` `0x0117` (`:681-689`). Sony records the JPEG with `JPEGInterchangeFormat`/`Length` (`0x0201`/`0x0202`) — the same pair that carries IFD0's 326 KB `PreviewImage`, which is likewise invisible for this reason.
- **The IFDs that ARE visited fail the compression filter.** `:655-660` requires `Compression == 7`; Sony IFD0 is 6 (old-style JPEG) and SubIFD is 32766 (Sony ARW compression). Only IFD2 has 7, and IFD2 is not visited.

Consequence for AD-022 bookkeeping: because the scan produces neither candidates nor "declared but unreadable" candidates, `embeddedProbe.malformed` is false, so these files take the ordinary `NativeImageNeedsRawDecode` path with `declaredPreviewsUnreadable: false` (`dart_image_loader.dart:234-242`). Nothing reports an error — the cost is silent: every ARW view pays a ~517 ms libraw sensor decode plus a ~78 ms re-encode where a 3.9 MB full-res JPEG (or a 326 KB sidebar-sized one) was sitting in the file. Sidebar thumbnails (`dart_image_loader.dart:105-115`) likewise miss and fall back to the sized decode path.

This is reported, not fixed, per assignment.

## 4. R2 detail

`scripts/tmp/arw_r2_bench.dart`, 20 files, sized-first/full-first alternated per file to blunt page-cache warm-up. Both calls go through the production wrappers `decodeDngSized(maxDim: 200)` / `decodeDngFull` (`dng_decode_service.dart:42,12`).

- sized(200): median 457 ms (446–517)
- full: median 505.5 ms (478–527)
- median per-file ratio 0.916 → **NOT FASTER** under the pre-registered 0.70 threshold.

Interpretation (stated as inference, not measurement): the libraw demosaic/sensor pass dominates and `maxDim` appears to cap only the output resize, so a 200 px request costs essentially a full decode. A sidebar built on `decodeDngSized` for these files therefore costs ~0.46 s per thumbnail.

## 5. Caveats

- All numbers are macOS/arm64 with the committed `libdng_decoder_native.dylib` loaded via `DNG_NATIVE_BUILD_DIR`, in a `dart run` process — no Flutter engine, no UI. Decode/encode wall times are honest for the CPU work but carry no UI-frame claim (per the standing "user measures UI perf" rule).
- Timings are single-shot per file (n=1 per file for the payload bench; the R2 bench is paired, n=20 files). No warm-up discards.
- The 125-file folder yielded 125 measured payloads; the earlier exiftool CSV has 127 rows, two of which are non-`.ARW`/non-numeric and were excluded from every sum (count shown in `tmp/verify/r1-compute.txt`).
- Top-60 selection is adversarial by design (largest 60 of 125). A realistic contiguous 60-item window would be smaller; that softer number was deliberately not computed as the headline.
