---
date: 2026-08-26
title: "Handoff — RAW format coverage gap: scan whitelist and non-DNG full decode"
---

## 🧭 檔案維護政策

**用途**：把 2026-08-26 README 重寫過程中查出的兩個 RAW 支援缺口，交接給後續實作任務。
本檔是交接文件，不是規格書；實作前需先依「開放問題」一節取得裁決。

**更新時機**：缺口被修復、或裁決結果出爐時更新；全部關閉後標記為已完成並停止更新。

**必填欄位**：`date`、`title`、現況證據（附檔案:行號）、開放問題、驗收條件草案。

**跨檔同步對象**：`memory.md`（若修復涉及架構決策，需新增 AD 條目）、`plan.md`（若排入
階段）、`README.md` 與 `README.zh-TW.md`（RAW 格式支援與解碼路由章節，修復後必須同步改寫）。

---

## Summary

Halcyon advertises itself as a RAW triage tool built on the Ceyx decoding engine. Ceyx
decodes a broad set of vendor RAW containers. Halcyon currently reaches a much smaller
set, for two independent reasons that are easy to conflate:

1. **The scan whitelist is narrower than Ceyx's coverage.** Six RAW extensions are listed.
   Files in any other RAW format never appear in the sidebar at all.
2. **Full RAW decode is wired for DNG only.** Of the six listed RAW extensions, only DNG
   can reach the decoder. The other five are displayable only when the camera wrote a
   usable embedded JPEG preview into the file.

These are separate fixes with separate risk profiles. Fixing (1) without (2) would make
more files appear in the sidebar while making the second gap more visible, not less.

Both were found while writing the README on 2026-08-26 and were verified independently by
the team lead, not taken on a single agent's report. The README states both plainly; if
either is fixed, the README's "RAW format support and decode routing" section and its
Chinese counterpart must be rewritten in the same change.

## Gap 1 — the scan whitelist

`SupportedPhotoFormats.supportedExtensions` lists nine extensions total:
`.jpg`, `.jpeg`, `.png`, `.dng`, `.cr2`, `.nef`, `.arw`, `.rw2`, `.orf`.

<!-- evidence: lib/models/supported_photo_formats.dart:6-16 -->

`PhotoLibraryScanner.scan` drops any directory entry failing
`SupportedPhotoFormats.isSupportedPath` before grouping, so an unlisted extension never
reaches any later stage — not the sidebar, not the decoder, not batch actions.

<!-- evidence: lib/services/library/photo_library_scanner.dart:11-16 -->

Ceyx documents decoding a substantially larger set. Absent from Halcyon's whitelist:

| Extension | Vendor / format | Note |
|---|---|---|
| `.raf` | Fujifilm | X-Trans sensors; one of the three sensor layouts Ceyx's GPU path handles explicitly |
| `.x3f` | Sigma | Foveon X3; the linear-RGB / no-CFA layout |
| `.cr3` | Canon | The current-generation Canon container; `.cr2` is the previous one |
| `.pef` | Pentax | |
| `.iiq` | Phase One | |
| `.mrw` | Minolta | |

<!-- evidence: /Users/jhangyu/project/ceyx/README.md:69-117 -->

Note that `.rw2` was once missing from this same whitelist and silently excluded, which is
recorded as a gotcha — this is a repeat of a known failure mode, not a novel one.

<!-- evidence: memory.md G-007 -->

## Gap 2 — full RAW decode is DNG-only

The Dart image loader emits the "needs raw decode" signal only for `.dng`, and says so in
its own invariant comment:

> `NativeImageNeedsRawDecode` is emitted ONLY for `purpose == ImageRequestPurpose.preview`
> on a `.dng`

<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart:12-15 -->

For any other RAW with no usable embedded preview, the loader returns a failure whose own
message states the situation:

> `RAW_NO_EMBEDDED_PREVIEW` — "no embedded preview and no decoder for this format"

<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart:114-119 -->

The only Ceyx entry point wired into Halcyon's Dart code is the DNG full decoder,
`DngDecoderService.decodeOnWorker`, wrapped as `halcyonDngFullDecoder`. No call site in
`lib/` invokes Ceyx's generic-RAW entry point.

<!-- evidence: lib/services/image_pipeline/dng_decode_service.dart:5-34 -->

The seam type is still named `DngFullDecoder` even though the engine behind it is now Ceyx
and decodes far more than DNG. The naming is a symptom of this gap, not the cause of it.

<!-- evidence: lib/services/image_pipeline/dng_decode_contract.dart:30 -->

## Constraints a fix must respect

These are recorded decisions, not preferences. Breaking them silently re-introduces bugs
the project already paid for once.

- **The result type is frozen at three variants.** `NativeImageResult` is a sealed class
  with exactly three variants and a documented prohibition on adding a fourth without
  sign-off. A generic-RAW route should reuse the existing `NativeImageNeedsRawDecode`
  signal rather than introduce a parallel one.
  <!-- evidence: lib/services/image_pipeline/image_source_types.dart:41-87, memory.md AD-010, AD-011 -->
- **The two "no preview" terminal states must stay distinguishable.** "The container
  declares no preview" routes to decode; "the container declares previews but none are
  readable" is a broken-file report. A generic-RAW path must preserve that distinction
  rather than collapsing both into "try decoding it".
  <!-- evidence: memory.md AD-022 -->
- **The minimum-long-edge floor is applied unevenly on purpose.** The preview path rejects
  undersized candidates; the sidebar and export paths stay lenient. Do not unify them.
  <!-- evidence: memory.md AD-021 -->
- **The native decoder does not exist on every platform.** The build script builds a Ceyx
  library for macOS, Windows and Android only; iOS, Linux and web have none. Widening
  format support widens the set of files that are unopenable on those three platforms,
  which is a user-visible regression there unless handled.
  <!-- evidence: scripts/build_apps.py:265-290 -->
- **Static analysis covers `lib/`, `test/` and `tool/`.** A change that sweeps only the
  first two will still fail the zero-issues gate.
  <!-- evidence: memory.md 2026-08-25 naming-refactor entry -->

## Open questions — need a decision before implementation starts

1. **Scope.** Fix Gap 2 only (full decode for the five already-listed RAW extensions), fix
   Gap 1 only (widen the whitelist), or both? Doing Gap 1 alone increases the number of
   files that display via embedded preview but cannot fall back to a decode.
2. **Sensor layouts.** Fujifilm X-Trans and Sigma Foveon are the two formats whose absence
   is most conspicuous to a photographer, and they are also the two that exercise Ceyx's
   non-Bayer GPU paths. Are those in scope, or is the first pass Bayer-only?
3. **Platform behaviour.** On iOS, Linux and web there is no decoder. Should a RAW with no
   usable preview be hidden from the sidebar on those platforms, shown with an explicit
   "cannot decode on this platform" state, or shown and left to fail?
4. **Test corpus.** Verifying a decode path needs real sample files per format. The
   existing corpus lives in `local_data/photo_samples/` and is untracked. Which formats can
   actually be sampled?

## Draft acceptance criteria (to be frozen once the questions above are answered)

- A file in each newly supported format appears in the sidebar after a folder scan.
- A file in each newly supported format, with its embedded preview stripped or absent,
  renders at full size through the decoder rather than returning
  `RAW_NO_EMBEDDED_PREVIEW`.
- `NativeImageResult` still has exactly three variants.
- The two "no preview" terminal states remain distinguishable, with a test per state.
- `flutter analyze` reports zero issues across `lib/`, `test/` and `tool/`.
- `flutter test` passes, with a new test case per newly supported format recorded in
  `unit_test.md`'s TC matrix.
- The decode-path behaviour on a platform with no native library is explicitly tested,
  matching whatever question 3 is answered with.
- `README.md` and `README.zh-TW.md` "RAW format support and decode routing" sections are
  rewritten to match the new reality, and the evidence notes in them re-verified.

## Not in scope

Renaming `DngFullDecoder` to something format-neutral. It is tempting and it is a separate
change with its own blast radius across `lib/`, `test/` and `tool/`; the 2026-08-25 naming
refactor is the cautionary precedent.
