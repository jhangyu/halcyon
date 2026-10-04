# INVARIANTS

Behaviours verified by the user that must hold across campaigns. Deleting or weakening any entry requires the user's
written ruling first (`.claude/CLAUDE.md` 不變條件與裁決). A commit that removes a capability must cite the ruling entry here.

Ruling source for the entries below: `docs/logs/2026-10-04/memreclaim-spec.md` §9 (OQ-1 "RULED 2026-10-04 (OQ-1 resolution)").

## INV-1 Windows idle and folder-switch memory falls

- **行為**: On Windows, resident memory (Task Manager) falls after the decode pool's quiescent idle shrink and after a
  folder switch. Reference: v1.0.17 idle ~600–800 MB; v1.0.18 regressed to ~1.2 GB when the working-set trim was deleted
  (`577191b`) and replaced by a no-op heap call.
- **適用平台**: Windows (first-class). Same contract on the other platforms per INV-2.
- **驗證方式**: (a) ceyx `native/tests/test_idle_funnel` bytes-measured cases F7/F9/F10 on the Windows host (reads
  `WorkingSetSize`, not `PrivateUsage`), run in ceyx prepush `test-bare-binaries`; (b) final acceptance of the 600–800 MB
  figure = the **user's own Task Manager reading** (agents never measure app UI/RSS).
- **對應測試名**: `F7_slot_discard_returns_resident`, `F9_allocator_trim_returns_free_pages`,
  `F10_cold_pages_handoff` (ceyx `native/tests/test_idle_funnel.cpp`); Halcyon `app_state_native_reclaim_test.dart`
  (`loadFolder requests one native reclaim per folder switch`). Landed in ceyx v0.1.33 / Halcyon v1.0.19.
- **裁決出處**: v1.0.9 onward user-verified; ruling 2026-09-12 (win-parity: supplement equivalent, do not delete);
  ruling 2026-10-04 OQ-1, `memreclaim-spec.md` §9.

## INV-2 Unified two-layer idle reclaim on all platforms

- **行為**: Every idle-funnel pass (`ceyx_native_idle_shrink`) runs, in this order on every platform:
  **Layer A** — return memory the app no longer needs (4a idle/floor pool-slot page discard; 4b allocator free pages;
  step 3 native device memory); **Layer B (step 5)** — hand cold live pages to the OS, content preserved.
  Bindings — A: macOS `MADV_FREE_REUSABLE` + `malloc_zone_pressure_relief`; Windows `DiscardVirtualMemory` +
  `VirtualUnlock` + `HeapSetInformation(HeapOptimizeResources)`; Linux `MADV_DONTNEED` + `malloc_trim`; Android
  `MADV_DONTNEED` + `M_PURGE_ALL`→`M_PURGE`. B: Windows `SetProcessWorkingSetSize(-1,-1)`; Linux/Android
  `madvise(MADV_PAGEOUT)` on private rw non-exec anonymous ranges (kernel ≥ 5.4, needs swap/zram). `HeapCompact` is never
  used (documented production no-op).
  Trigger: after every completed quiescent pool shrink (debounced), plus folder switch via a pending request that fires
  after ≥ 1 s decode quiescence, is cancelled by any decode, and respects the grow lockout. Never synchronous, never
  zero-delay, never armed by navigation/user idleness.
  **Approved platform exceptions (technically unreachable, user-approved 2026-10-04):** (i) macOS step 5 =
  `unavailable` (no app-callable API: `MADV_PAGEOUT` "internal only"/ENOTSUP, `VM_BEHAVIOR_PAGEOUT` "development only";
  Activity Monitor counts compressed pages anyway); (ii) Android API 21–27 step 4b = `unavailable` (OQ-5; 4a still runs;
  API 28+ runs the full reclaim).
- **適用平台**: macOS, Windows, Linux, Android (iOS/Web ship no ceyx native library — N/A).
- **驗證方式**: ceyx prepush `test-bare-binaries` on macOS + Windows hosts; one docker run (Linux, with swap) and one adb
  run (Android) per OQ-6 — if F10/G5 is red there the implementer stops and reports. Perf-regression gates G1–G5
  (cadence/thrash, slot re-fault ≤ 1.5×, first-decode-after-idle ≤ +15 ms, reclaim-call caller-thread p95 ≤ 8 ms,
  cold-page re-access ≤ 2.0×). Remote CI only checks that the `ceyx_native_idle_shrink` export symbol exists.
- **對應測試名**: `F7c_no_slots_no_drop`, `F7_slot_discard_returns_resident`, `F8_discarded_slot_reusable`,
  `F9_allocator_trim_returns_free_pages`, `F10_cold_pages_handoff`, `G2_slot_refault_cost`,
  `G4_reclaim_call_duration`, `G5_cold_page_refault_cost` (ceyx `native/tests/test_idle_funnel.cpp`);
  `plugin/test/reclaim_cadence_test.dart` (G1), `plugin/test/reclaim_request_test.dart`. Landed in ceyx v0.1.33 / Halcyon
  v1.0.19.
- **裁決出處**: `memreclaim-spec.md` §9 OQ-1 "RULED 2026-10-04 (OQ-1 resolution)" items 1–4 (Windows binding of item 6 is
  a lead decision, not a user ruling), OQ-2 (trigger conditions), OQ-5 (Android API 21–27), OQ-6 (verification vehicle).

## INV-3 Reclaim effects are accepted by measured bytes, never by call counts

- **行為**: A reclaim capability counts as landed on a platform only when a run on that platform measures the resident
  figure dropping by the pre-registered amount (and, for step 5, content intact on re-read). Call counters, symbol
  existence, or "compiles" prove wiring only and are never an acceptance basis. Each case must be shown red (mutation in a
  scratch worktree) before it counts; no SKIP — an unobservable precondition is a FAIL.
- **適用平台**: all platforms with a ceyx native library.
- **驗證方式**: `test_idle_funnel` self-measures its own process (Windows `WorkingSetSize`, Apple `phys_footprint`,
  Linux/Android `RssAnon`) against fixed thresholds; per-host red-proof artifact `memreclaim-redproof-<host>.txt`
  contains `F7_slot_discard_returns_resident -> FAIL`, `F9_allocator_trim_returns_free_pages -> FAIL`,
  `F10_cold_pages_handoff -> FAIL` and `PREPUSH_BARE_CASE test_idle_funnel FAIL`.
- **對應測試名**: `F7_slot_discard_returns_resident`, `F9_allocator_trim_returns_free_pages`,
  `F10_cold_pages_handoff` (+ red-proof procedure `memreclaim-spec.md` §5.1).
- **裁決出處**: `.claude/CLAUDE.md` 多平台實作鐵律「以實測為準」; ruling 2026-10-04 OQ-1 / OQ-3 (headless test binary may
  read its own resident memory), `memreclaim-spec.md` §5 and §9.

## INV-4 Single decoded tier: full resolution only, band −1..+2, budget 423 MiB accepted

- **行為**: The image pipeline keeps exactly one decoded-pixels tier — full resolution from the retained q70 payload — over
  the asymmetric band {cur−1 .. cur+2} (4 slots). No viewport/window-resolution decode tier may be reintroduced. The
  resulting image-cache budget increase 382 → 423 MiB (3×(96+19.4)MB → 4×96MB working set, ×1.15) is explicitly accepted
  by the user: "多這個41mb記憶體佔用沒問題，至少換到的是有用的東西" (2026-10-04). This increase must still not break
  INV-1 (Windows idle/folder-switch memory drops): the tier-removal implementer must state INV-1 impact in the Phase 2
  review, and any later change claiming INV-1 regression traces back here.
  User ruling 2026-10-04 (P-4): minimum target RAM is 4 GiB; the budget is the derived band need (423 MiB at 24 MP) on
  every machine, with NO machine-memory ceiling and NO floor. Pinned by TC-1482 (`retention_test.dart`).
- **適用平台**: all (pure Dart pipeline; same path everywhere).
- **驗證方式**: `flutter test test/services/image_pipeline/full_res_band_test.dart` (band coverage, slot count 4, budget
  formula); grep `lib/` for `tierOne|kWindowResolutionImageByteCost` → zero hits.
- **對應測試名**: TC-1461..TC-1465 (`full_res_band_test.dart`), TC-1460 double-skip regression (`full_res_convergence_test.dart:69`).
- **裁決出處**: user rulings 2026-10-04 (this session): "1->拔掉視窗解析度 全解析度窗改-1~+2" and the 41 MiB acceptance
  quoted above; contract `docs/logs/2026-10-04/viewport-tier-removal-contract.md`.

## INV-5 MRW / Minolta support is removed permanently

- **行為**: The MRW (Minolta) format does not exist anywhere in the codebase: no extension, registry entry, parser, test
  or doc. It must not be reintroduced. The browse-only RAW set is `{.cr2, .iiq}`.
- **適用平台**: all.
- **驗證方式**: `grep -riE "mrw|minolta" lib test` returns zero hits (contract AC4); `flutter analyze` = 0 issues.
- **對應測試名**: TC-1481 `.mrw (Minolta) is not a known extension anywhere (INV-5)`
  (`test/models/supported_photo_formats_test.dart`).
- **裁決出處**: user ruling R2 in `docs/logs/2026-10-04/preview-extraction-contract.md`: "MRW format is deleted from the
  entire codebase, no traces (code, registry, tests, docs), per unreleased-dev no-compat policy." Removal commit `027600a`
  cites this entry.

## INV-6 Full-size embedded JPEG is accepted only at ≥ 90% of sensor extent; extraction stays pure Dart

- **行為**: A full-size request (`longEdge == null`) accepts an embedded JPEG only when its longest side is
  ≥ 0.90 × sensor extent (`cropMax`). The rule is not relaxed to viewport-fill; a smaller JPEG falls back to RAW decode.
  Preview requests (explicit floor) are unaffected. The sensor extent comes from a format-generic baseline (not DNG-only
  tag 0xC620), and RAF/X3F containers are parsed in pure Dart; no native extraction is introduced.
- **適用平台**: all (same Dart code path).
- **驗證方式**: `flutter test test/services/image_pipeline/raw_container_extractor_test.dart`; code constant
  `0.90 * cropMax` at `lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart:622` and `:1258`.
- **對應測試名**: `JPEG under 90% of the raw extent is still rejected for full-size`,
  `finds the JPEG section; full-size accepts at >=90% of raw extent` (X3F), `NEF-like TIFF without DefaultCropSize:
  full-size selects the JPEG` (all in `raw_container_extractor_test.dart`).
- **裁決出處**: user ruling R1 in `docs/logs/2026-10-04/preview-extraction-contract.md`: "Size threshold stays rule (a) —
  full-size requests accept an embedded JPEG only at ≥90% of sensor extent. Do NOT relax to viewport-fill."

## INV-7 `ceyx_debug_idle_funnel_counters` is called with 10 out-pointers (cross-reference)

- **行為**: Halcyon's two callers pass all 10 out-pointers the native signature expects (it gained
  `cold_handoff_ran/unavailable/refused`); passing fewer makes native write through garbage.
- **適用平台**: all platforms with the ceyx native library (callers: `lib/perf/perf_driver.dart`,
  `tools/memgate/memgate.py`).
- **驗證方式**: code review of the two call sites (fix commit `d5bf7ec`).
- **對應測試名**: no test pins the pointer count (`test/perf/perf_driver_memgate_test.dart` only checks counter printing).
- **裁決出處**: Task 6 ruling R4 (2026-10-04), held in the ceyx repo's `INVARIANTS.md` (R4).
