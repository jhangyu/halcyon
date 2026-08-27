# Spec — Machine-Adaptive Payload Retention (perf review proposal 3)

> Date: 2026-08-28 · Author: spec-adaptive-opus (team `spec-plans`) · HEAD `e664ff9`
> Status: **SPEC ONLY — implementation deferred to a future session.**
> Source: `docs/logs/2026-08-28/perf-review-report.md` §3, `perf-review-memory-lifecycle.md` Finding 2.

## 1. Goal

One sentence: **give the app a real total-physical-memory reading and use it to size
both the payload retention window and the two byte budgets, so a high-RAM machine
retains more forward slots instead of re-paying an ~8.5 s RAW decode on
back-navigation — while a machine with no memory reading behaves exactly as it does
today.**

Two parts, in order:

- **Part A — memory source.** No physical-memory reading exists anywhere in the app.
  `dart:io` has no platform-neutral total-RAM API (`ProcessInfo` is RSS only), and
  constraint **C-3** forbids `Platform.isX` / `kIsWeb` / `defaultTargetPlatform` /
  conditional imports in `lib/` (`docs/logs/2026-08-24/m6-execution-plan.md:18`; the
  single enumerated exception is the F-19 reveal site in `status_line.dart`). So the
  source must be a `MethodChannel`: platform-neutral in Dart, per-platform on the
  native side, absent platforms answer with `MissingPluginException`.
- **Part B — sizing.** Feed that reading into `imageCacheBudgetBytes` (the seam already
  exists but is called with `null`) and into a new retention policy that sizes
  `kRetentionAfter` and the payload byte budget. Today's `-3..+5` / 224 MiB is the
  **low-RAM floor** and also the no-reading default.

## 2. Scope

**In scope**

1. `MethodChannel('halcyon/device_memory')` with one method, `totalPhysicalBytes`.
2. macOS native implementation in `macos/Runner/AppDelegate.swift` (the only platform
   with a real implementation in this proposal).
3. Dart wrapper returning `Future<int?>` — `null` on missing plugin, platform error,
   non-integer or non-positive value.
4. A pure `retentionPolicyFor({int? physicalMemoryBytes})` sizing function returning a
   `RetentionPolicy` (before / after / payloadByteBudget).
5. Threading the policy: `main.dart` → `AppState` → `ImagePreloadController` →
   `PhotoPayloadCache.byteBudget` and the retention-window call sites.
6. Wiring the same reading into `configureImageCache()` / `imageCacheBudgetBytes`.
7. Tests for every item above; `unit_test.md` matrix rows.

**Out of scope**

- Windows / Linux / Android / iOS native implementations. They keep returning
  `MissingPluginException` → `null` → today's floor values. Adding them later is one
  method handler per runner and needs no Dart change.
- Tuning the high-RAM window depth against real UI measurement. The user measures UI
  performance (agents may not); the ladder in §4.3 is a conservative first setting and
  is expected to be tuned by the user afterwards.
- The tier-2 full-size decode window (`kTierTwoRadius`) — owned by proposal 1.
- Any change to eviction ordering, payload kinds, `SourcePayload.byteCost`, tier-1 /
  tier-2 identity or ImageCache key invariants.
- Runtime re-sizing (memory pressure notifications, re-reading RAM after launch). The
  reading is taken once at startup.

## 3. Current behavior — evidence at HEAD `e664ff9`

| Fact | Location |
|---|---|
| Retention window is two compile-time constants, `-3..+5` | `lib/services/image_pipeline/photo_payload_cache.dart:6,10` |
| Payload budget is a compile-time constant 224 MiB (= 234,881,024 B), sized to hold exactly one `-3..+5` RAW window (201.59 MiB) + ~11 % headroom | `lib/services/image_pipeline/photo_payload_cache.dart:31` |
| Re-entering an evicted no-preview RAW slot costs a full sequential RAW decode, ~8.5 s measured | `lib/services/image_pipeline/photo_payload_cache.dart:26` |
| `PhotoPayloadCache` already accepts `byteBudget` as a constructor argument (default = the constant) | `lib/services/image_pipeline/photo_payload_cache.dart:50-52` |
| `retentionWindowIds` already takes `before:` / `after:` parameters (defaulting to the constants) | `lib/services/image_pipeline/photo_payload_cache.dart:183-194` |
| The controller builds its cache with no arguments, and reads the constants directly at two window sites | `image_preload_controller.dart:89`, `:413-417`, `:456-460`, `:878-897` |
| ImageCache sizing seam exists and is *not* wired to any source: `physicalMemoryBytes: null` | `lib/main.dart:16-23`, `lib/services/image_pipeline/cache_budget.dart:34-39` |
| With `null`, `imageCacheBudgetBytes` returns its own ceiling, 768 MiB | `cache_budget.dart:32,37`; asserted at `test/services/image_pipeline/cache_budget_test.dart:7` and `test/main_test.dart:21-33` |
| C-3 forbids `Platform.isX`, `kIsWeb`, `defaultTargetPlatform`, conditional imports in `lib/` | `docs/logs/2026-08-24/m6-execution-plan.md:18`; guard grep at `:1048` |
| Existing `MethodChannel` pattern to copy (Dart side, `MissingPluginException` handling) | `lib/services/platform/trash_service.dart:7-19` |
| Existing `MethodChannel` registration pattern (native side) | `macos/Runner/AppDelegate.swift:23-40` |
| Eviction already degrades farthest-first, so a wider window needs no new eviction logic | `photo_payload_cache.dart:78,148-173` |
| Perf build stamp logs the payload budget constant | `lib/perf/perf_log.dart:18,69` |

Net: **both** tiers are fixed at runtime today; the payload tier does not even have a seam.

## 4. Proposed design

### 4.1 Part A — the memory source

New file `lib/services/platform/device_memory.dart`:

```dart
class DeviceMemory {
  static const MethodChannel channel = MethodChannel('halcyon/device_memory');

  /// Total physical RAM in bytes, or null when no platform answers.
  static Future<int?> totalPhysicalBytes() async { ... }
}
```

- Returns `null` on `MissingPluginException` (every platform without a handler),
  `PlatformException`, a null reply, or a value `<= 0`. It never throws.
- **C-3-safe by construction**: the Dart side names no platform. Which platform
  answers is decided by which runner registered the handler. The C-3 guard grep
  (`Platform\.is|kIsWeb|defaultTargetPlatform`) stays clean.

Native, macOS only — one more channel in `AppDelegate.applicationDidFinishLaunching`,
following the `halcyon/trash` shape: on `totalPhysicalBytes`, reply
`Int(ProcessInfo.processInfo.physicalMemory)`; on any other method,
`FlutterMethodNotImplemented`.

**Platform coverage table**

| Platform | Behavior after this change |
|---|---|
| macOS | Real reading from `ProcessInfo.processInfo.physicalMemory`. |
| Windows, Linux, Android, iOS, web | No handler → `MissingPluginException` → `null` → floor policy (`-3..+5`, 224 MiB) and the 768 MiB ImageCache ceiling — byte-for-byte today's behavior. |
| Unit tests / widget tests | No handler by default → `null` → floor. Tests that need a reading install a mock handler on the channel. |

### 4.2 Part B — sizing

New file `lib/services/image_pipeline/retention_policy.dart`:

```dart
class RetentionPolicy {
  const RetentionPolicy({
    required this.before,
    required this.after,
    required this.payloadByteBudget,
  });
  const RetentionPolicy.floor()
      : before = kRetentionBefore, after = kRetentionAfter,
        payloadByteBudget = kPayloadByteBudget;
  final int before;
  final int after;
  final int payloadByteBudget;
}

RetentionPolicy retentionPolicyFor({int? physicalMemoryBytes});
```

`kRetentionBefore`, `kRetentionAfter`, `kPayloadByteBudget` stay where they are and
keep their current values — they become *the floor*, not dead constants, so every
existing test that references them still compiles and still asserts the shipped floor.

### 4.3 The ladder

`before` never changes (backward revisits are the rare direction; widening backward
buys the least). Only `after` and the budget scale. Each rung's budget is
`slots × 22.4 MiB × 1.11`, rounded **up** to a whole MiB — the same derivation that
produced today's 224 MiB (`photo_payload_cache.dart:19-30`; 22.4 MiB = measured
window-resolution RGBA per no-preview RAW item).

| Rung | Trigger | before | after | slots | requirement | payloadByteBudget |
|---|---|---|---|---|---|---|
| floor | reading is `null`, or `< 12 GiB` | 3 | 5 | 9 | 201.59 MiB | 224 MiB (234,881,024 B) |
| mid | `>= 12 GiB` | 3 | 8 | 12 | 268.80 MiB | 304 MiB (318,767,104 B) |
| high | `>= 32 GiB` | 3 | 11 | 15 | 336.00 MiB | 384 MiB (402,653,184 B) |

Thresholds are chosen against the machines this app actually ships on (8 / 16 / 24 /
32 / 64 GiB Apple silicon): 16 GiB and 24 GiB take the mid rung, 32 GiB and up take
high. A rung's budget is never allowed above `physicalMemoryBytes / 32` — at the rung
triggers that is 384 MiB (12 GiB) and 1 GiB (32 GiB), so the ladder satisfies it with
room to spare; the bound is asserted by a test rather than enforced at runtime, so a
future edit that breaks it fails loudly instead of shipping.

The ImageCache tier needs **no new function** — `imageCacheBudgetBytes` already
implements quarter-of-RAM clamped to [256 MiB, 768 MiB]. It only needs to be *called
with the reading*.

### 4.4 Threading

```
main()  ── await DeviceMemory.totalPhysicalBytes() ──┬─ configureImageCache(physicalMemoryBytes: ram)
                                                     └─ AppState(retention: retentionPolicyFor(physicalMemoryBytes: ram))
                                                            └─ ImagePreloadController(retention: …)
                                                                   ├─ PhotoPayloadCache(byteBudget: retention.payloadByteBudget)
                                                                   └─ retentionWindowIds(…, before: retention.before, after: retention.after)
```

- `configureImageCache({int? physicalMemoryBytes})` gains an optional named parameter
  defaulting to `null`, so `test/main_test.dart:21-33` (which calls it with no
  arguments and expects 768 MiB) keeps passing unchanged.
- `AppState({RetentionPolicy retention = const RetentionPolicy.floor(), …})` and
  `ImagePreloadController({RetentionPolicy retention = const RetentionPolicy.floor(), …})`
  both default to the floor, so all ~20 existing controller construction sites in
  `test/` compile untouched.
- `main()` becomes `Future<void> main() async`, awaiting one channel round trip
  (single-digit ms on macOS; `null` immediately elsewhere) before `runApp`.
- `PerfLog` build stamp (`lib/perf/perf_log.dart:69`) must log the **effective**
  budget, not the constant — otherwise the perf log misreports the machine it ran on.
  Simplest honest form: `PerfLog.init` takes the effective budget as a parameter.

## 5. Acceptance criteria (mechanically checkable)

- [ ] **AC-1** `grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/ | grep -v perf_driver` prints nothing (exit 1). C-3 stays clean.
- [ ] **AC-2** `lib/services/platform/device_memory.dart` exists and declares `MethodChannel('halcyon/device_memory')`.
- [ ] **AC-3** `macos/Runner/AppDelegate.swift` contains `halcyon/device_memory` and `ProcessInfo.processInfo.physicalMemory`.
- [ ] **AC-4** `DeviceMemory.totalPhysicalBytes()` returns `null` — not a throw — for each of: no handler registered, `PlatformException`, `null` reply, reply `0`, reply `-1`. Test: `test/services/platform/device_memory_test.dart`.
- [ ] **AC-5** `retentionPolicyFor` returns exactly the floor rung for `null`, `1 GiB`, and `11 GiB`; the mid rung for `12 GiB`, `16 GiB`, `24 GiB`; the high rung for `32 GiB`, `64 GiB`. Exact values per the §4.3 table, asserted as raw byte counts (224 MiB = `234881024`, 304 MiB = `318767104`, 384 MiB = `402653184`).
- [ ] **AC-6** For every rung: `payloadByteBudget >= ceil((before+after+1) * 22.4 MiB)` and `payloadByteBudget <= rungTriggerBytes / 32`. Asserted in `test/services/image_pipeline/retention_policy_test.dart`.
- [ ] **AC-7** `RetentionPolicy.floor()` equals `(before: kRetentionBefore, after: kRetentionAfter, payloadByteBudget: kPayloadByteBudget)` — the shipped constants are the floor, not a second copy of them.
- [ ] **AC-8** An `ImagePreloadController` constructed with a mid/high policy retains slots out to `+after` and drops `+after+1`, proved by the existing window-test harness style (`test/services/image_pipeline/image_preload_window_test.dart`).
- [ ] **AC-9** An `ImagePreloadController` constructed with no `retention` argument behaves exactly as today (retains `-3..+5`) — i.e. every pre-existing test in `test/services/image_pipeline/` passes unmodified.
- [ ] **AC-10** `configureImageCache()` (no argument) still yields `805306368`; `configureImageCache(physicalMemoryBytes: 2 GiB)` yields `536870912`.
- [ ] **AC-11** `flutter analyze` reports 0 issues; `flutter test` is green with the declared test count equal to the executed count (`-j 1`, exit code captured in-artifact per the repo's measurement rules).
- [ ] **AC-12** `docs/sop/unit_test.md` gains matrix rows TC-310…TC-320 covering the new tests.
- [ ] **AC-13** Live proof on macOS: a debug run logs one line reporting the reading and the chosen rung, and the value matches `sysctl -n hw.memsize` on that machine.

## 6. Risks

1. **`await` before `runApp`.** One channel round trip delays the first frame. Mitigation: the call is a single `invokeMethod` with no I/O; if it ever measures badly, move to a post-first-frame re-size (out of scope now). Stated so the implementer does not "optimize" it into a fire-and-forget that races the controller's construction.
2. **Wiring a real reading changes ImageCache behavior on low-RAM machines.** Today every machine gets 768 MiB. After this, a machine with `< 3 GiB` RAM drops to 512 or 256 MiB. That is the intended behavior of `imageCacheBudgetBytes`, but it *is* a behavior change on small machines and must be called out in the commit message.
3. **The high-RAM depth is unmeasured.** `after: 8/11` is derived from byte arithmetic, not from UI measurement — and agents are barred from UI/RSS measurement in this repo. The rungs are deliberately conservative (≤ 384 MiB of held `Uint8List`); the user tunes them afterwards. Do not present them as measured.
4. **Widening `after` widens the tier-1 precache span too** (`_precacheTierOneWindow` derives its span from the same constants, `image_preload_controller.dart:878-897`). That is deliberate — it is the reason the span was derived rather than hardcoded — but it means more ImageCache entries on high-RAM machines. The larger ImageCache budget from Part B is what absorbs it; the two parts must land together, not separately.
5. **Windows/Linux/Android/iOS silently stay on the floor.** Honest, and identical to today's behavior, but someone reading "machine-adaptive retention" in the changelog may assume all platforms adapt. The commit message and `memory.md` note must say macOS-only.
6. **`ProcessInfo.processInfo.physicalMemory` is `UInt64`.** On a hypothetical > 8 EiB machine the `Int` conversion overflows; not a practical risk, but the handler should not force-unwrap anything and the Dart side already rejects non-positive values.
