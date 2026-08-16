# Round 1 — Native squad (Plan C) handoff

Squad: native (native-lead-opus / native-impl-1-sonnet / native-test-haiku)
Scope: `macos/Runner/AppDelegate.swift` only. Shared main tree, baseline af2e73f.
Status: complete, signed off by orchestrator. No round 2 planned.

## 1. Completed work + evidence

**Change**: in `getFastThumbnail`, added an early fast path inside the existing
`DispatchQueue.global(qos: .userInteractive)` block, before `CGImageSourceCreateWithURL`:
when `purpose == "preview"` and the lowercased path ends in `.jpg`/`.jpeg`, read
`Data(contentsOf: url)` and return it via `FlutterStandardTypedData` on the main queue,
then `return`. Full-resolution `createFullSizeImage` decode and the NSBitmapImageRep
JPEG re-encode (quality 0.8) are skipped entirely for that case.

| Item | Value |
|---|---|
| Commit | `adfa6246fa47f5fb63e230dd1cfb36cbc027176b` — `perf(macos): return original JPEG bytes for preview requests, skip decode/re-encode` |
| Files | `macos/Runner/AppDelegate.swift` only (20 insertions / 2 deletions) |
| Build evidence (pre-merge) | `tmp/verify/native-build-20260816-115207.txt` — exit 0, `Built build/macos/Build/Products/Debug/Halcyon.app` |
| Build evidence (post-merge gate) | `tmp/verify/native-postmerge-20260816-120932.txt` — HEAD and HEAD_AFTER both `7c33194331808b540bce73e2da728e47f1b13c3f`, EXIT=0 |

**Negative-space review** (lead-performed, against the file and the diff):
`git diff -U0 --ignore-all-space` yields zero deleted lines — the two "deletions" in the
stat are trailing-whitespace-only. Untouched: RAW embedded-thumbnail path, CIRAWFilter
fallback, non-JPEG preview `createFullSizeImage` path, sidebarThumbnail path, both
pre-existing error paths, `trashFile`, `createFullSizeImage`.

Three consumer-visible deltas, all confined to the preview+JPEG case:

- Native-applied EXIF orientation is gone; the engine decoder now applies it from the bytes.
- Payload is the original file, no longer a 0.8-quality re-encode.
- Read-failure message changes `"Cannot read source"` to `"Cannot read image"` (same
  `LOAD_FAILED` code). Inert: the only caller, `lib/services/native_thumbnail_service.dart:33`,
  catches `PlatformException` generically without inspecting code or message.

`targetSize` was already ignored on this path before the change (`createFullSizeImage`
never honored it), so no delta there.

**EXIF verification**: the orientation assumption was checked empirically by an independent
opus reviewer, not merely assumed from the contract — the engine decoder applies
`Orientation=6` correctly. Review verdict: CONFIRMED.

## 2. Known limitations

- **No automated test covers the native path at all.** Correctness rests on the macOS build
  plus the reviewer's manual EXIF check. A regression here fails silently in CI.
- **Only orientation value 6 was exercised.** Values 3, 5, 7, 8 and the mirrored variants
  are untested; they route through the same engine code path, but that is inference, not evidence.
- **Mislabeled or corrupt `.jpg`**: previously ImageIO sniffed content and could still return
  a valid image; now the failure surfaces as a Flutter-side decode error instead of a native
  `LOAD_FAILED`. Low risk — no such files are known in use.
- **Uncapped payload**: very large JPEGs now cross the MethodChannel at full file size.
  A bytes cap is Plan D, explicitly out of scope this round.

## 3. Interface contracts

None. The squad owned a single file, had no cross-squad interface dependency, and the
MethodChannel signature (`getThumbnail` with `path` / `purpose` / `targetSize`, returning
bytes) is unchanged.

## 4. Next-round notes

Parking-lot items, verbatim as reported to the orchestrator, none acted on:

- A mislabeled/corrupt .jpg now surfaces as a Flutter-side decode failure instead of a native
  LOAD_FAILED; previously ImageIO would sniff by content and could still return a valid image.
  Low risk, no known such files.
- Very large JPEGs now cross the channel at full file size; no bytes cap exists (that is
  out-of-scope Plan D).
- No automated test covers the native path at all; correctness rests on the build plus the
  contract's EXIF assumption. Only a manual visual check of a rotated JPEG would close it.

Still out of scope per the frozen contract (contract lines 14-21): Plan B (low-res fallback),
Plan D (bytes LRU cache), HEIC/PNG preview downsampling, RAW decode optimization, the empty
Android `MainActivity.kt` handler, and the `preview targetSize=10000` value.

Live check for anyone revisiting this:

    grep -n "isPreviewRequest && isJpeg" macos/Runner/AppDelegate.swift
