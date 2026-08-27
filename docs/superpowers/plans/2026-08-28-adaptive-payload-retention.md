# Machine-Adaptive Payload Retention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use podium:team-spawn (recommended) or podium:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Halcyon a real total-physical-memory reading (macOS `MethodChannel`, safe `null` everywhere else) and size the payload retention window, the payload byte budget, and the Flutter `ImageCache` budget from it — keeping today's `-3..+5` / 224 MiB / 768 MiB as the floor and the no-reading default.

**Architecture:** One new platform wrapper (`DeviceMemory.totalPhysicalBytes()`) reads RAM over `MethodChannel('halcyon/device_memory')`; one new pure function (`retentionPolicyFor`) maps that reading to a `RetentionPolicy` value object (before / after / payloadByteBudget) on a three-rung ladder; `main()` reads once at startup and injects the policy down `AppState → ImagePreloadController → PhotoPayloadCache`, and the same reading into the already-existing `imageCacheBudgetBytes` seam. Everything defaults to the floor, so every existing construction site and test is unaffected.

**Tech Stack:** Flutter 3.35 / Dart 3.9, `flutter/services.dart` `MethodChannel`, Swift (`FlutterMacOS`), `flutter_test`.

## Global Constraints

- Spec of record: `docs/logs/2026-08-28/spec-adaptive-payload-retention.md`. Every acceptance criterion below traces to it.
- **C-3:** `Platform.isX`, `kIsWeb`, `defaultTargetPlatform`, conditional imports and shelled-out platform binaries are forbidden in `lib/` (single enumerated exception: `status_line.dart`). Guard: `grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/ | grep -v perf_driver` must print nothing.
- `kRetentionBefore = 3`, `kRetentionAfter = 5`, `kPayloadByteBudget = 234881024` keep their current values and stay in `lib/services/image_pipeline/photo_payload_cache.dart`. They become the floor rung; they are not duplicated anywhere.
- Rung budgets, as raw byte counts: floor `234881024` (224 MiB), mid `318767104` (304 MiB), high `402653184` (384 MiB). Rung triggers: mid `>= 12 GiB` (`12 * 1024 * 1024 * 1024`), high `>= 32 GiB`. `before` is `3` on every rung.
- Real memory reading is **macOS only**. All other platforms get `MissingPluginException` → `null` → floor. Never fake a reading.
- `flutter analyze` must report 0 issues before any task is considered done.
- `flutter test` is run with `-j 1`; capture the exit code in-artifact with `RC=$?` on the line immediately after the command — never `${PIPESTATUS[0]}`, never a harness-reported code.
- Test additions get rows in `docs/sop/unit_test.md`; architecture decisions/gotchas go in `docs/sop/memory.md`.
- Commits follow Conventional Commits. Commit with an explicit pathspec: `git commit -- <paths>` (shared working tree).

---

# Stage 1 — Skeleton

### Task 1: `DeviceMemory` platform wrapper (Dart side)

**Files:**
- Create: `lib/services/platform/device_memory.dart`
- Test: `test/services/platform/device_memory_test.dart`

**Interfaces:**
- Consumes: nothing (leaf).
- Produces:
  - `class DeviceMemory`
  - `static const MethodChannel DeviceMemory.channel` — `MethodChannel('halcyon/device_memory')`, public so tests can name it.
  - `static Future<int?> DeviceMemory.totalPhysicalBytes()`

**Behavior:**
Invokes `totalPhysicalBytes` on the channel and returns the reply as `int?`. Returns `null` — never throws — for: `MissingPluginException` (every platform with no handler, and every unit test that installs none), `PlatformException`, a `null` reply, and any reply `<= 0`. A non-positive reading is treated as absent because a zero/negative RAM figure is a broken platform, not a small machine, and must not be fed to the sizing ladder.

**Constraints:**
- No `Platform.isX` / `kIsWeb` / `defaultTargetPlatform` (C-3). The Dart side names no platform.
- No caching, no retries, no timeout logic — one call, one answer. (YAGNI: `main()` calls it once.)
- Mirrors `lib/services/platform/trash_service.dart:7-19`'s exception shape; unlike `TrashService` it swallows rather than rethrows, because absence of a reading is a supported state.

**Acceptance criteria:**
- [ ] `test/services/platform/device_memory_test.dart` exists and passes with 5 cases: no handler → `null`; handler returns `17179869184` → `17179869184`; handler returns `null` → `null`; handler returns `0` → `null`; handler throws `PlatformException` → `null`.
- [ ] `grep -n "halcyon/device_memory" lib/services/platform/device_memory.dart` matches.
- [ ] `grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/services/platform/device_memory.dart` prints nothing.

---

### Task 2: macOS native handler + live proof

**Files:**
- Modify: `macos/Runner/AppDelegate.swift:15-49` (inside `applicationDidFinishLaunching`, after the `halcyon/trash` registration)

**Interfaces:**
- Consumes: `DeviceMemory.channel` name `halcyon/device_memory` from Task 1.
- Produces: a native handler replying to method `totalPhysicalBytes` with an `Int` byte count; `FlutterMethodNotImplemented` for any other method.

**Behavior:**
Registers a third `FlutterMethodChannel` on the same binary messenger as the existing two. On `totalPhysicalBytes`, replies `Int(ProcessInfo.processInfo.physicalMemory)`. Reply is synchronous — `physicalMemory` is a cheap sysctl-backed property, no dispatch to a background queue needed (unlike `trashFile`, which does filesystem work). No force-casts anywhere, matching the file's existing "never force-cast" rule at `:16-22`.

**Constraints:**
- The channel object must be held only as a local — it is pull-only (Dart → native), so unlike `openWithChannel` there is nothing to retain for later pushes.
- Do not touch the `halcyon/trash` or `halcyon/open_with` registrations.
- No other runner (Windows/Linux/Android/iOS) is modified in this plan.

**Acceptance criteria:**
- [ ] `grep -n "halcyon/device_memory" macos/Runner/AppDelegate.swift` matches.
- [ ] `grep -n "ProcessInfo.processInfo.physicalMemory" macos/Runner/AppDelegate.swift` matches.
- [ ] `flutter build macos --debug` succeeds.
- [ ] **Live proof:** a debug run prints the `startup.memory|` line added in Task 5 and its `bytes=` value equals `sysctl -n hw.memsize` on the same machine.

---

### Task 3: `RetentionPolicy` + `retentionPolicyFor` sizing ladder

**Files:**
- Create: `lib/services/image_pipeline/retention_policy.dart`
- Test: `test/services/image_pipeline/retention_policy_test.dart`

**Interfaces:**
- Consumes: `kRetentionBefore`, `kRetentionAfter`, `kPayloadByteBudget` from `lib/services/image_pipeline/photo_payload_cache.dart`.
- Produces:
  - `class RetentionPolicy` with `final int before`, `final int after`, `final int payloadByteBudget`
  - `const RetentionPolicy({required int before, required int after, required int payloadByteBudget})`
  - `const RetentionPolicy.floor()` — equals `(3, 5, 234881024)` by referencing the constants
  - `operator ==` / `hashCode` (so tests can compare policies directly)
  - `String toString()` — `RetentionPolicy(-3..+5, 234881024 B)` shape, used by the startup log line
  - `RetentionPolicy retentionPolicyFor({int? physicalMemoryBytes})`
  - `const int kMidRungTriggerBytes = 12 * 1024 * 1024 * 1024;`
  - `const int kHighRungTriggerBytes = 32 * 1024 * 1024 * 1024;`

**Behavior:**
Pure function, no I/O. `null` or `< kMidRungTriggerBytes` → floor; `>= kMidRungTriggerBytes` and `< kHighRungTriggerBytes` → `(3, 8, 318767104)`; `>= kHighRungTriggerBytes` → `(3, 11, 402653184)`. `before` is 3 on every rung: backward revisits are the rare direction, so widening backward buys the least per byte held. Budgets follow the derivation already in `photo_payload_cache.dart:19-30` — `slots × 22.4 MiB × 1.11`, rounded up to a whole MiB (12 slots → 298.4 → 304 MiB; 15 slots → 372.96 → 384 MiB).

**Constraints:**
- No dependency on `dart:io`, `flutter/services.dart`, or anything platform-shaped — this file must be testable in a plain `test()` with no binding.
- Must not redeclare the floor numbers; `RetentionPolicy.floor()` references the existing constants (spec AC-7).
- Ladder is a plain `if` chain — no config file, no environment variable, no injection point. (YAGNI: the user tunes by editing these numbers.)

**Acceptance criteria:**
- [ ] `retentionPolicyFor(physicalMemoryBytes: null)`, `(1 GiB)`, `(11 GiB)` each equal `const RetentionPolicy.floor()`.
- [ ] `(12 GiB)`, `(16 GiB)`, `(24 GiB)` each equal `const RetentionPolicy(before: 3, after: 8, payloadByteBudget: 318767104)`.
- [ ] `(32 GiB)`, `(64 GiB)` each equal `const RetentionPolicy(before: 3, after: 11, payloadByteBudget: 402653184)`.
- [ ] `RetentionPolicy.floor().before == kRetentionBefore`, `.after == kRetentionAfter`, `.payloadByteBudget == kPayloadByteBudget`.
- [ ] Invariant test: for each of the three rungs, `payloadByteBudget >= ((before+after+1) * 22.4 * 1024 * 1024).ceil()` and `payloadByteBudget <= trigger ~/ 32` (floor rung's trigger for this check is `kMidRungTriggerBytes`).

---

### Task 4: Thread the policy through the preload pipeline

**Files:**
- Modify: `lib/services/image_pipeline/image_preload_controller.dart:76-89` (constructor + `_cache` field), `:409-417` (retention sweep), `:456-460` (near-to-far span), `:876-897` (tier-1 precache span)
- Modify: `lib/providers/app_state.dart:61-91` (constructor)
- Test: `test/services/image_pipeline/image_preload_window_test.dart` (append cases)

**Interfaces:**
- Consumes: `RetentionPolicy`, `RetentionPolicy.floor()` (Task 3); `PhotoPayloadCache({int byteBudget})` and `retentionWindowIds<T>(List<T>, int, String Function(T), {int before, int after})`, both already existing at `photo_payload_cache.dart:50,183`.
- Produces:
  - `ImagePreloadController({required NativeImageLoad imageLoader, DngFullDecoder? dngDecoder, DngSizedDecoder? sidebarRawDecoder, RetentionPolicy retention = const RetentionPolicy.floor()})`
  - `RetentionPolicy get ImagePreloadController.retention`
  - `AppState({… , RetentionPolicy retention = const RetentionPolicy.floor()})`
  - `RetentionPolicy get AppState.retentionPolicy`

**Behavior:**
The controller stores the policy and uses it in the three places that currently read the constants directly:
1. the retention sweep's `retentionWindowIds(...)` call gains `before: _retention.before, after: _retention.after`;
2. the near-to-far span's `startIdx`/`endIdx` clamps use `_retention.before` / `_retention.after`;
3. `_precacheTierOneWindow`'s `tierStart`/`tierEnd` clamps and its `retentionWindowIds` call likewise.
The cache is built with `PhotoPayloadCache(byteBudget: retention.payloadByteBudget)`, which forces `_cache` from a field initializer to a constructor initializer. `AppState` accepts the policy and forwards it when it constructs the default controller; when the caller injects a `preloadController` directly, `AppState.retentionPolicy` reports that controller's own policy so the two can never disagree.

**Constraints:**
- Defaults are `const RetentionPolicy.floor()` everywhere, so all ~20 existing `ImagePreloadController(...)` sites in `test/` and the `AppState` site compile and behave unchanged (spec AC-9).
- No change to eviction ordering, `setEvictionPriority`, `SourcePayload`, tier-2 scheduling, or ImageCache key identity.
- The tier-1 precache span must keep being **derived** from the same policy, not hardcoded — that derivation is why a retained slot and a screen-resolution entry cannot drift apart (`image_preload_controller.dart:876-884` comment).
- Do not touch `kTierTwoRadius` or `tier_two_scheduler.dart` — a separate proposal owns them.

**Acceptance criteria:**
- [ ] A controller built with `RetentionPolicy(before: 3, after: 8, payloadByteBudget: 318767104)` retains the ids at `+6..+8` after navigating, and drops `+9`.
- [ ] A controller built with no `retention` argument retains exactly `-3..+5` (existing behavior).
- [ ] `grep -c "kRetentionBefore\|kRetentionAfter" lib/services/image_pipeline/image_preload_controller.dart` is `0`.
- [ ] `flutter test test/services/image_pipeline/ -j 1` green, declared count == executed count.

---

### Task 5: Wire startup, the ImageCache budget, the perf stamp, and the docs

**Files:**
- Modify: `lib/main.dart:15-50`
- Modify: `lib/perf/perf_log.dart:18,44,66-70`
- Modify: `lib/perf/perf_driver.dart:65`
- Modify: `docs/sop/unit_test.md` (matrix rows TC-310…TC-320), `docs/sop/memory.md` (one AD entry)
- Test: `test/main_test.dart` (append cases)

**Interfaces:**
- Consumes: `DeviceMemory.totalPhysicalBytes()` (Task 1), `retentionPolicyFor` / `RetentionPolicy` (Task 3), `AppState({RetentionPolicy retention})` and `AppState.retentionPolicy` (Task 4), `imageCacheBudgetBytes({int? physicalMemoryBytes})` (existing, `cache_budget.dart:34`).
- Produces:
  - `void configureImageCache({int? physicalMemoryBytes})`
  - `Future<void> main()`
  - `static void PerfLog.init(String outPath, {int payloadByteBudget = kPayloadByteBudget})`

**Behavior:**
`main()` becomes async: after `ensureInitialized()` it awaits one `DeviceMemory.totalPhysicalBytes()` call, passes the reading to `configureImageCache(physicalMemoryBytes: ram)` and to `retentionPolicyFor(physicalMemoryBytes: ram)`, and hands the resulting policy to `AppState`. It then prints exactly one line via `debugPrint` — `startup.memory|bytes=<n or null>|policy=<policy>` — which is the live proof required by Task 2 and by the repo's rule that a mechanism claim needs a real run. `PerfLog.init` takes the effective budget so the build stamp reports the machine it actually ran on instead of the compile-time constant; `PerfDriver._run` passes `state.retentionPolicy.payloadByteBudget`.

**Constraints:**
- `configureImageCache`'s parameter is optional and defaults to `null`, so `test/main_test.dart:21-33` (calls it with no arguments, expects `805306368`) still passes untouched.
- The await must stay *before* `runApp` — a fire-and-forget read would race the `AppState` construction and silently ship the floor policy. This is called out in the spec's risk 1; do not "optimize" it away.
- Exactly one startup log line, via `debugPrint` (not `print`) — the repo has an `avoid_print` lint that `PerfLog` opts out of by an explicit ignore.
- The commit message must state: real reading is macOS-only, and low-RAM machines (`< 3 GiB`) now get a smaller ImageCache than the previous unconditional 768 MiB.

**Acceptance criteria:**
- [ ] `configureImageCache()` → `PaintingBinding.instance.imageCache.maximumSizeBytes == 805306368`.
- [ ] `configureImageCache(physicalMemoryBytes: 2 * 1024 * 1024 * 1024)` → `536870912`.
- [ ] `grep -n "startup.memory" lib/main.dart` matches.
- [ ] `grep -c "kPayloadByteBudget" lib/perf/perf_log.dart` is `2` (the import and the default parameter value) and the build stamp interpolates the parameter, not the constant.
- [ ] `docs/sop/unit_test.md` contains `TC-310` … `TC-320`.
- [ ] `flutter analyze` → `No issues found!`; `flutter test -j 1` green with declared count == executed count; C-3 guard grep prints nothing.

---

# Stage 2 — Implementation steps

## Task 1 steps

- [ ] **Step 1.1: Write the failing test**

Create `test/services/platform/device_memory_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/device_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(DeviceMemory.channel, null);
  });

  test('TC-310: no platform handler yields null, not a throw', () async {
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });

  test('TC-311: a positive reading is returned as-is', () async {
    messenger.setMockMethodCallHandler(DeviceMemory.channel, (call) async {
      expect(call.method, 'totalPhysicalBytes');
      return 17179869184; // 16 GiB
    });
    expect(await DeviceMemory.totalPhysicalBytes(), 17179869184);
  });

  test('TC-312: a null reply yields null', () async {
    messenger.setMockMethodCallHandler(
      DeviceMemory.channel,
      (call) async => null,
    );
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });

  test('TC-313: a non-positive reading is treated as absent', () async {
    messenger.setMockMethodCallHandler(
      DeviceMemory.channel,
      (call) async => 0,
    );
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });

  test('TC-314: a PlatformException yields null, not a throw', () async {
    messenger.setMockMethodCallHandler(DeviceMemory.channel, (call) async {
      throw PlatformException(code: 'BOOM');
    });
    expect(await DeviceMemory.totalPhysicalBytes(), isNull);
  });
}
```

- [ ] **Step 1.2: Run it to make sure it fails**

Run:
```bash
cd /Users/jhangyu/project/Halcyon
flutter test test/services/platform/device_memory_test.dart -j 1
```
Expected: FAIL at compile — `Error: Couldn't resolve the package 'halcyon_flutter/services/platform/device_memory.dart'` (target file does not exist yet).

- [ ] **Step 1.3: Implement**

Create `lib/services/platform/device_memory.dart`:

```dart
import 'package:flutter/services.dart';

/// Total physical RAM of the host machine, over a platform channel.
///
/// There is no platform-neutral total-memory API in `dart:io` (`ProcessInfo`
/// reports this process's RSS, not the machine's RAM) and C-3 forbids
/// `Platform.isX` branches in `lib/`, so the only C-3-safe source is a
/// channel: this file names no platform, and WHICH platform answers is
/// decided by which runner registered a handler.
///
/// Only macOS ships a handler today. Everywhere else the call raises
/// [MissingPluginException] and this returns null, which every consumer
/// reads as "use the floor sizing" -- i.e. exactly today's behavior.
class DeviceMemory {
  static const MethodChannel channel = MethodChannel('halcyon/device_memory');

  /// Total physical memory in bytes, or null when no platform answers.
  ///
  /// Never throws. A non-positive reply is treated as absent: a zero or
  /// negative RAM figure is a broken platform, not a small machine, and
  /// must not be fed to the sizing ladder.
  static Future<int?> totalPhysicalBytes() async {
    try {
      final bytes = await channel.invokeMethod<int>('totalPhysicalBytes');
      if (bytes == null || bytes <= 0) return null;
      return bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
```

- [ ] **Step 1.4: Run the tests and make sure they pass**

Run:
```bash
flutter test test/services/platform/device_memory_test.dart -j 1
```
Expected: `+5: All tests passed!`

- [ ] **Step 1.5: Check C-3 and analyze**

Run:
```bash
grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/ | grep -v perf_driver ; echo "GREP_RC=$?"
flutter analyze
```
Expected: `GREP_RC=1` (no matches) and `No issues found!`

- [ ] **Step 1.6: Commit**

```bash
git add lib/services/platform/device_memory.dart test/services/platform/device_memory_test.dart
git commit -- lib/services/platform/device_memory.dart test/services/platform/device_memory_test.dart \
  -m "feat(platform): add C-3-safe total-physical-memory channel wrapper"
```

---

## Task 2 steps

- [ ] **Step 2.1: Add the native handler**

In `macos/Runner/AppDelegate.swift`, immediately after the `trashChannel.setMethodCallHandler({...})` block (currently ending at line 40) and before the `openWithChannel` creation, insert:

```swift
    // Total physical RAM, for machine-adaptive cache sizing (Dart side:
    // lib/services/platform/device_memory.dart). Pull-only, so unlike
    // openWithChannel there is nothing to retain: the channel object may
    // die with this scope once the handler is installed on the messenger.
    let deviceMemoryChannel = FlutterMethodChannel(name: "halcyon/device_memory",
                                                   binaryMessenger: controller.engine.binaryMessenger)
    deviceMemoryChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "totalPhysicalBytes" {
        // physicalMemory is a cheap sysctl-backed property; no background
        // dispatch needed (unlike trashFile, which touches the filesystem).
        result(Int(ProcessInfo.processInfo.physicalMemory))
      } else {
        result(FlutterMethodNotImplemented)
      }
    })
```

- [ ] **Step 2.2: Build**

Run:
```bash
flutter build macos --debug
```
Expected: `Built build/macos/Build/Products/Debug/halcyon_flutter.app` (or equivalent success line), exit 0.

- [ ] **Step 2.3: Verify the markers**

Run:
```bash
grep -n "halcyon/device_memory" macos/Runner/AppDelegate.swift
grep -n "ProcessInfo.processInfo.physicalMemory" macos/Runner/AppDelegate.swift
```
Expected: one match each.

- [ ] **Step 2.4: Commit**

```bash
git commit -- macos/Runner/AppDelegate.swift \
  -m "feat(macos): serve total physical memory over halcyon/device_memory"
```

> Live proof of the end-to-end reading is Step 5.9 — the Dart consumer that prints it does not exist until Task 5.

---

## Task 3 steps

- [ ] **Step 3.1: Write the failing test**

Create `test/services/image_pipeline/retention_policy_test.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

void main() {
  const gib = 1024 * 1024 * 1024;
  const floor = RetentionPolicy.floor();
  const mid = RetentionPolicy(
    before: 3,
    after: 8,
    payloadByteBudget: 318767104, // 304 MiB
  );
  const high = RetentionPolicy(
    before: 3,
    after: 11,
    payloadByteBudget: 402653184, // 384 MiB
  );

  test('TC-315: no reading and low-RAM machines get today shipped floor', () {
    expect(retentionPolicyFor(physicalMemoryBytes: null), floor);
    expect(retentionPolicyFor(physicalMemoryBytes: 1 * gib), floor);
    expect(retentionPolicyFor(physicalMemoryBytes: 11 * gib), floor);
    // The floor IS the shipped constants, not a second copy of them.
    expect(floor.before, kRetentionBefore);
    expect(floor.after, kRetentionAfter);
    expect(floor.payloadByteBudget, kPayloadByteBudget);
    expect(floor.payloadByteBudget, 234881024, reason: '224 MiB exactly');
  });

  test('TC-316: the mid and high rungs trigger at 12 GiB and 32 GiB', () {
    expect(retentionPolicyFor(physicalMemoryBytes: 12 * gib), mid);
    expect(retentionPolicyFor(physicalMemoryBytes: 16 * gib), mid);
    expect(retentionPolicyFor(physicalMemoryBytes: 24 * gib), mid);
    expect(retentionPolicyFor(physicalMemoryBytes: 32 * gib), high);
    expect(retentionPolicyFor(physicalMemoryBytes: 64 * gib), high);
  });

  test('TC-317: every rung holds its own RAW window and stays modest', () {
    // 22.4 MiB = measured window-resolution RGBA per no-preview RAW item
    // (photo_payload_cache.dart:19-30). A rung must hold one full window...
    const perSlotBytes = 22.4 * 1024 * 1024;
    // ...and must never claim more than 1/32 of the RAM that triggered it.
    final rungs = <RetentionPolicy, int>{
      floor: kMidRungTriggerBytes,
      mid: kMidRungTriggerBytes,
      high: kHighRungTriggerBytes,
    };
    rungs.forEach((policy, triggerBytes) {
      final slots = policy.before + policy.after + 1;
      expect(
        policy.payloadByteBudget,
        greaterThanOrEqualTo((slots * perSlotBytes).ceil()),
        reason: 'rung $policy cannot hold one full RAW window',
      );
      expect(
        policy.payloadByteBudget,
        lessThanOrEqualTo(triggerBytes ~/ 32),
        reason: 'rung $policy claims more than 1/32 of its trigger RAM',
      );
    });
    // Guard the ladder shape itself: budgets grow with slots.
    expect(
      <int>[floor.after, mid.after, high.after],
      orderedEquals(<int>[5, 8, 11]),
    );
    expect(
      math.min(mid.payloadByteBudget, high.payloadByteBudget),
      greaterThan(floor.payloadByteBudget),
    );
  });
}
```

- [ ] **Step 3.2: Run it to make sure it fails**

Run:
```bash
flutter test test/services/image_pipeline/retention_policy_test.dart -j 1
```
Expected: FAIL at compile — cannot resolve `.../retention_policy.dart`.

- [ ] **Step 3.3: Implement**

Create `lib/services/image_pipeline/retention_policy.dart`:

```dart
import 'photo_payload_cache.dart';

/// A machine gets the mid rung at or above this much RAM.
const int kMidRungTriggerBytes = 12 * 1024 * 1024 * 1024;

/// A machine gets the high rung at or above this much RAM.
const int kHighRungTriggerBytes = 32 * 1024 * 1024 * 1024;

/// How much the payload cache keeps, and how far forward it reaches.
///
/// The floor rung is EXACTLY the constants this app has always shipped
/// ([kRetentionBefore] / [kRetentionAfter] / [kPayloadByteBudget]); a machine
/// with no memory reading -- which is every platform except macOS today --
/// behaves byte-for-byte as it did before this type existed.
class RetentionPolicy {
  const RetentionPolicy({
    required this.before,
    required this.after,
    required this.payloadByteBudget,
  });

  /// The shipped floor. Referenced, not re-typed, so the two cannot drift.
  const RetentionPolicy.floor()
    : before = kRetentionBefore,
      after = kRetentionAfter,
      payloadByteBudget = kPayloadByteBudget;

  final int before;
  final int after;
  final int payloadByteBudget;

  @override
  bool operator ==(Object other) =>
      other is RetentionPolicy &&
      other.before == before &&
      other.after == after &&
      other.payloadByteBudget == payloadByteBudget;

  @override
  int get hashCode => Object.hash(before, after, payloadByteBudget);

  @override
  String toString() =>
      'RetentionPolicy(-$before..+$after, $payloadByteBudget B)';
}

/// Sizes retention from total physical memory.
///
/// [before] never grows: back-navigation is the rare direction, so widening
/// backward buys the least per byte held. Each rung's budget is
/// `slots * 22.4 MiB * 1.11` rounded up to a whole MiB -- the same derivation
/// that produced the shipped 224 MiB (photo_payload_cache.dart:19-30), where
/// 22.4 MiB is the measured window-resolution RGBA cost of one no-preview RAW
/// item and the 11% is headroom above the row the cache must hold.
///
/// The rung DEPTHS are byte arithmetic, not UI measurement -- UI measurement
/// in this repo is the user's to run. They are deliberately conservative
/// (at most 384 MiB of held `Uint8List`) and are expected to be tuned.
RetentionPolicy retentionPolicyFor({int? physicalMemoryBytes}) {
  if (physicalMemoryBytes == null ||
      physicalMemoryBytes < kMidRungTriggerBytes) {
    return const RetentionPolicy.floor();
  }
  if (physicalMemoryBytes < kHighRungTriggerBytes) {
    // 12 slots -> 268.80 MiB required, 304 MiB budgeted.
    return const RetentionPolicy(
      before: 3,
      after: 8,
      payloadByteBudget: 304 * 1024 * 1024,
    );
  }
  // 15 slots -> 336.00 MiB required, 384 MiB budgeted.
  return const RetentionPolicy(
    before: 3,
    after: 11,
    payloadByteBudget: 384 * 1024 * 1024,
  );
}
```

- [ ] **Step 3.4: Run the tests and make sure they pass**

Run:
```bash
flutter test test/services/image_pipeline/retention_policy_test.dart -j 1
flutter analyze
```
Expected: `+3: All tests passed!` and `No issues found!`

- [ ] **Step 3.5: Commit**

```bash
git commit -- lib/services/image_pipeline/retention_policy.dart \
  test/services/image_pipeline/retention_policy_test.dart \
  -m "feat(image-pipeline): add the retention sizing ladder"
```

---

## Task 4 steps

- [ ] **Step 4.1: Write the failing test**

Append to `test/services/image_pipeline/image_preload_window_test.dart`, inside the existing top-level `main()`, next to TC-098a. Reuse this file's own helpers exactly as its neighbours do: `rawItems(int)` (`:80`), `cheapController()` (`:91`), `fakeDecoded()` (`:85`), `_until(bool Function(), {String? reason})` (`:47`), the retained-payload accessor `controller.payloadFor(id)` (`:288`), and the named-argument call shape `preloadImages(items:, selectedItemId:, notifyLoaded:)` (`:279-283`). Add the import `package:halcyon_flutter/services/image_pipeline/retention_policy.dart` at the top of the file.

```dart
  test('TC-318 a mid-rung policy fills out to +8 and retains nothing at +9',
      () async {
    const midRung = RetentionPolicy(
      before: 3,
      after: 8,
      payloadByteBudget: 318767104,
    );
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async => fakeDecoded(),
      retention: midRung,
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(10, 10);

    final photos = rawItems(30);
    const selected = 12;
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[selected].id,
      notifyLoaded: () {},
    );
    await _until(
      () => List.generate(
        midRung.before + midRung.after + 1,
        (i) => photos[selected - midRung.before + i].id,
      ).every((id) => controller.payloadFor(id) != null),
      reason: 'every slot of the mid-rung -3..+8 window to acquire a payload',
    );

    expect(
      controller.payloadFor(photos[selected + midRung.after].id),
      isNotNull,
      reason: '+8 is inside the mid rung and must hold a payload',
    );
    expect(
      controller.payloadFor(photos[selected + midRung.after + 1].id),
      isNull,
      reason: '+9 is outside the mid rung and must never be retained',
    );
  });

  test('TC-319 the default policy is still the shipped -3..+5 floor', () async {
    final controller = cheapController();
    addTearDown(controller.dispose);
    controller.updateTargetSize(10, 10);
    expect(controller.retention, const RetentionPolicy.floor());

    final photos = rawItems(30);
    const selected = 12;
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[selected].id,
      notifyLoaded: () {},
    );
    await _until(
      () => controllerWindowFilled(controller, photos, selected),
      reason: 'the -3..+5 floor window to fill',
    );

    expect(
      controller.payloadFor(photos[selected + kRetentionAfter + 1].id),
      isNull,
      reason: 'the default controller must not reach past +5',
    );
  });
```

Note on TC-319: `cheapController()` (`:91`) uses an `imageLoader` that returns PNG bytes and a `dngDecoder` that fails the test if called, so `rawItems` here exercise the cheap rung — that is fine, the assertion is about the window span, not the rung. `controllerWindowFilled` is the file's existing `-3..+5` helper (`:57`).

- [ ] **Step 4.2: Run it to make sure it fails**

Run:
```bash
flutter test test/services/image_pipeline/image_preload_window_test.dart -j 1
```
Expected: FAIL at compile — `No named parameter with the name 'retention'` and `The getter 'retention' isn't defined for the class 'ImagePreloadController'`.

- [ ] **Step 4.3: Add the policy to the controller's constructor**

In `lib/services/image_pipeline/image_preload_controller.dart`, replace the constructor and the `_cache` field (currently `:76-89`):

```dart
  ImagePreloadController({
    required NativeImageLoad imageLoader,
    DngFullDecoder? dngDecoder,
    DngSizedDecoder? sidebarRawDecoder,
    this.retention = const RetentionPolicy.floor(),
  }) : _source = PhotoSource(loader: imageLoader, dngDecoder: dngDecoder),
       _sidebarRawDecoder = sidebarRawDecoder,
       _cache = PhotoPayloadCache(byteBudget: retention.payloadByteBudget);

  /// How far retention reaches and how many bytes it may hold. Sized from
  /// total physical memory at startup (see retention_policy.dart); the
  /// default is the shipped floor, so every test and every platform without
  /// a memory reading behaves exactly as before.
  final RetentionPolicy retention;
```

and change the field declaration to:

```dart
  final PhotoPayloadCache _cache;
```

Add the import next to the other `image_pipeline` imports:

```dart
import 'retention_policy.dart';
```

- [ ] **Step 4.4: Use the policy at the three window sites**

Retention sweep (`:413-417`):

```dart
    final neededIds = retentionWindowIds(
      items,
      currentIndex,
      (item) => item.id,
      before: retention.before,
      after: retention.after,
    );
```

Near-to-far span (`:456-460`):

```dart
    final startIdx = (currentIndex - retention.before).clamp(
      0,
      items.length - 1,
    );
    final endIdx = (currentIndex + retention.after).clamp(0, items.length - 1);
```

Tier-1 precache span (`:878-897`) — clamps and the helper call both:

```dart
    final tierStart = (currentIndex - retention.before).clamp(
      0,
      items.length - 1,
    );
    final tierEnd = (currentIndex + retention.after).clamp(
      0,
      items.length - 1,
    );
    final neededIds = retentionWindowIds<PhotoItem>(
      items,
      currentIndex,
      (item) => item.id,
      before: retention.before,
      after: retention.after,
    );
```

- [ ] **Step 4.5: Thread the policy through `AppState`**

In `lib/providers/app_state.dart`, add the parameter and forward it (constructor at `:61-91`):

```dart
  AppState({
    PhotoLibraryScanner? scanner,
    PhotoStatusStore? statusStore,
    PhotoFileActions? fileActions,
    ImagePreloadController? preloadController,
    NativeImageLoad? imageLoader,
    DngFullDecoder? dngDecoder,
    PhotoExportService? exportService,
    ExifBatchReader? exifReader,
    RetentionPolicy retention = const RetentionPolicy.floor(),
  }) : ...
       _preloadController =
           preloadController ??
           ImagePreloadController(
             imageLoader: imageLoader ?? dartImageLoad,
             dngDecoder: dngDecoder,
             sidebarRawDecoder: dngDecoder == null
                 ? null
                 : halcyonDngSizedDecoder,
             retention: retention,
           ) {
```

(keep every existing comment in that constructor body as-is), add the import:

```dart
import '../services/image_pipeline/retention_policy.dart';
```

and add the getter next to the other read-only accessors:

```dart
  /// The policy actually in force. Read from the controller rather than the
  /// constructor argument, so an injected controller and this getter can
  /// never disagree.
  RetentionPolicy get retentionPolicy => _preloadController.retention;
```

- [ ] **Step 4.6: Run the tests and make sure they pass**

Run:
```bash
flutter test test/services/image_pipeline/ -j 1
flutter analyze
```
Expected: all green, `No issues found!`, and the declared test count equals the executed count.

- [ ] **Step 4.7: Prove the constants are gone from the controller**

Run:
```bash
grep -c "kRetentionBefore\|kRetentionAfter" lib/services/image_pipeline/image_preload_controller.dart
```
Expected: `0`

- [ ] **Step 4.8: Commit**

```bash
git commit -- lib/services/image_pipeline/image_preload_controller.dart \
  lib/providers/app_state.dart \
  test/services/image_pipeline/image_preload_window_test.dart \
  -m "refactor(image-pipeline): take the retention window from an injected policy"
```

---

## Task 5 steps

- [ ] **Step 5.1: Write the failing test**

Append to `test/main_test.dart` (inside the existing `main()`, next to the existing `configureImageCache` test at `:21-33`):

```dart
  testWidgets(
    'TC-320: configureImageCache derives the budget from a supplied reading',
    (tester) async {
      configureImageCache(physicalMemoryBytes: 2 * 1024 * 1024 * 1024);
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        536870912,
        reason: '2 GiB / 4 = 512 MiB, above the 256 MiB floor',
      );

      configureImageCache();
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        805306368,
        reason: 'no reading still means the 768 MiB ceiling',
      );
    },
  );
```

- [ ] **Step 5.2: Run it to make sure it fails**

Run:
```bash
flutter test test/main_test.dart -j 1
```
Expected: FAIL at compile — `No named parameter with the name 'physicalMemoryBytes'`.

- [ ] **Step 5.3: Implement the `main.dart` wiring**

In `lib/main.dart`, replace `configureImageCache` and `main` (`:15-50`), keeping the rest of the file untouched:

```dart
void configureImageCache({int? physicalMemoryBytes}) {
  // M6 F-25/P5.1 seam, now actually fed: DeviceMemory supplies the reading on
  // macOS and null everywhere else, and null yields the same fixed ceiling
  // this app shipped before. dart:io still has no platform-neutral
  // total-physical-memory API (ProcessInfo is RSS-only) and Platform.isX
  // branches are forbidden (C-3), which is why the reading arrives over a
  // channel instead of from Dart. See
  // lib/services/image_pipeline/cache_budget.dart for the sizing rationale.
  PaintingBinding.instance.imageCache.maximumSizeBytes = imageCacheBudgetBytes(
    physicalMemoryBytes: physicalMemoryBytes,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ONE reading, taken before runApp. It must be awaited here rather than
  // fired off: AppState is constructed on the next line, and a late-arriving
  // reading would silently leave the app on the floor policy while looking
  // like it adapted. Real reading on macOS only; null (-> floor) elsewhere.
  final physicalMemoryBytes = await DeviceMemory.totalPhysicalBytes();
  configureImageCache(physicalMemoryBytes: physicalMemoryBytes);
  final retention = retentionPolicyFor(
    physicalMemoryBytes: physicalMemoryBytes,
  );
  // The one line that makes the mechanism self-reporting: without it, "the
  // app adapts to this machine" is a claim about code rather than an
  // observed fact. Compared against `sysctl -n hw.memsize` on macOS.
  debugPrint('startup.memory|bytes=$physicalMemoryBytes|policy=$retention');
  // Composition root: injects the real RAW decoder. When dngDecoder is null
  // (tests, and any platform without the native dylib) a DNG carrying no
  // embedded preview is a PERMANENT MISS -- there is no legacy decode channel
  // left to fall back to. See the dngDecoder comment in AppState's constructor.
  final appState = AppState(
    dngDecoder: halcyonDngFullDecoder,
    retention: retention,
  ); // PERF-INSTRUMENTATION
  // Finder "Open With" / shell association: load the file's folder and select
  // that photo. Registered before runApp so a launch-time file isn't missed.
  OpenWithChannel.listen(appState.openPhotoAtPath);
  runApp(
    ChangeNotifierProvider.value(
      value: appState, // PERF-INSTRUMENTATION
      child: const HalcyonApp(),
    ),
  );
  // PERF-INSTRUMENTATION
  if (PerfDriver.active) {
    PerfDriver.run(appState);
  }
}
```

Add these imports beside the existing ones:

```dart
import 'services/image_pipeline/retention_policy.dart';
import 'services/platform/device_memory.dart';
```

(`debugPrint` comes from `package:flutter/material.dart`, already imported at `:1`.)

- [ ] **Step 5.4: Run the test and make sure it passes**

Run:
```bash
flutter test test/main_test.dart -j 1
```
Expected: all tests pass, including the pre-existing 768 MiB case unchanged.

- [ ] **Step 5.5: Make the perf build stamp report the effective budget**

In `lib/perf/perf_log.dart`, change the `init` signature (`:44`) and the stamp (`:66-70`):

```dart
  static void init(String outPath, {int payloadByteBudget = kPayloadByteBudget}) {
```

```dart
    log(
      'build.stamp|commit=$kHalcyonBuildCommit'
      '|imageCacheMaxBytes=${PaintingBinding.instance.imageCache.maximumSizeBytes}'
      '|kPayloadByteBudget=$payloadByteBudget',
    );
```

(The field name in the log stays `kPayloadByteBudget` — the perf-log format is a stable contract for downstream parsers, per the header note at `perf_log.dart:10-12`. Only the VALUE becomes the effective one.)

In `lib/perf/perf_driver.dart:65`:

```dart
    PerfLog.init(_out, payloadByteBudget: state.retentionPolicy.payloadByteBudget);
```

- [ ] **Step 5.6: Run the whole suite**

Run:
```bash
flutter analyze
flutter test -j 1 2>&1 | tail -5 ; RC=$?
echo "TEST_RC=$RC"
```
Expected: `No issues found!`, `All tests passed!`, `TEST_RC=0`, and the `+N` count equal to the declared case count.

- [ ] **Step 5.7: Update the docs**

In `docs/sop/unit_test.md`, add matrix rows for TC-310…TC-320 naming each test file and the behavior it pins (memory-channel null/positive/error paths; the three ladder rungs and the ladder invariants; the mid-rung retention window; the default floor window; the ImageCache derivation).

In `docs/sop/memory.md`, add one AD entry recording: the memory reading arrives over `MethodChannel('halcyon/device_memory')` because C-3 forbids `Platform.isX` and `dart:io` has no total-RAM API; the reading is macOS-only today and every other platform falls to the shipped floor; the ladder numbers are byte arithmetic, not UI measurement, and are the user's to tune.

- [ ] **Step 5.8: Commit**

```bash
git commit -- lib/main.dart lib/perf/perf_log.dart lib/perf/perf_driver.dart \
  test/main_test.dart docs/sop/unit_test.md docs/sop/memory.md \
  -m "feat(image-pipeline): size retention and the image cache from physical memory

Real reading is macOS-only (halcyon/device_memory); every other platform gets
null and keeps the shipped -3..+5 / 224 MiB floor. Note the one behavior change
on small machines: with a real reading, a host under 3 GiB now gets a 512 or
256 MiB ImageCache instead of the previous unconditional 768 MiB."
```

- [ ] **Step 5.9: Live proof on macOS (this is the task's real acceptance)**

Run:
```bash
sysctl -n hw.memsize
flutter run -d macos --debug 2>&1 | grep -m1 "startup.memory"
```
Expected: the `bytes=` value in the `startup.memory|` line equals the `sysctl` output exactly, and `policy=` names the rung the ladder predicts for that number (e.g. a 32 GiB machine → `RetentionPolicy(-3..+11, 402653184 B)`). Paste both numbers into the task log; a plan step is not complete on "the code looks right".

- [ ] **Step 5.10: Final gates**

Run:
```bash
grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/ | grep -v perf_driver ; echo "C3_RC=$?"
grep -c "kRetentionBefore\|kRetentionAfter" lib/services/image_pipeline/image_preload_controller.dart
grep -n "TC-310\|TC-320" docs/sop/unit_test.md
```
Expected: `C3_RC=1`, `0`, and one match for each TC id.

---

## Self-Review (run by the plan author, 2026-08-28)

**1. Spec coverage**

| Spec item | Task |
|---|---|
| §2 in-scope 1 (channel) + AC-2 | Task 1 |
| §2 in-scope 2 (macOS native) + AC-3 | Task 2 |
| §2 in-scope 3 (Dart wrapper, null paths) + AC-4 | Task 1 (TC-310…314) |
| §2 in-scope 4 (`retentionPolicyFor`) + AC-5, AC-6, AC-7 | Task 3 (TC-315…317) |
| §2 in-scope 5 (threading) + AC-8, AC-9 | Task 4 (TC-318, TC-319) |
| §2 in-scope 6 (ImageCache wiring) + AC-10 | Task 5 (TC-320) |
| §2 in-scope 7 (tests + `unit_test.md`) + AC-12 | Steps 1.1, 3.1, 4.1, 5.1, 5.7 |
| AC-1 (C-3 guard) | Steps 1.5, 5.10 |
| AC-11 (analyze + suite) | Steps 4.6, 5.6, 5.10 |
| AC-13 (live proof) | Step 5.9 |
| §4.4 perf-stamp correction | Step 5.5 |
| §6 risk 1 (await before runApp) | Task 5 Constraints + Step 5.3 comment |
| §6 risk 2 (low-RAM ImageCache change) | Step 5.8 commit message |
| §6 risk 4 (tier-1 span widens with the policy) | Task 4 Constraints + Step 4.4 |
| §6 risk 5 (macOS-only) | Step 5.7 `memory.md` entry |

No gaps. §2 out-of-scope items (other platforms' native handlers, UI tuning, `kTierTwoRadius`, runtime re-sizing) have no task, as intended.

**2. Placeholder scan**

No `TBD` / `TODO` / "implement later" / "similar to Task N" / "add appropriate error handling" anywhere: the error paths are enumerated by name (`MissingPluginException`, `PlatformException`, null reply, non-positive reply) with the required behavior for each. Every code step carries the actual code; every run step carries the exact command and the expected output. Step 4.1's test code was rewritten after reading the target file: it now uses that file's real API (`preloadImages(items:, selectedItemId:, notifyLoaded:)`, `controller.payloadFor(id)`, `_until`, `controllerWindowFilled`, `fakeDecoded`) rather than an invented `debugRetainedIds` accessor, and every helper it names is cited with a line number.

**3. Type consistency**

- `RetentionPolicy(before:, after:, payloadByteBudget:)` and `RetentionPolicy.floor()` — identical in Task 3's Interfaces, Task 3's code, Task 4's code, Task 5's code, and all tests.
- `retentionPolicyFor({int? physicalMemoryBytes})` → `RetentionPolicy` — consistent in Tasks 3 and 5.
- `DeviceMemory.totalPhysicalBytes()` → `Future<int?>`, `DeviceMemory.channel` — consistent in Tasks 1, 5, and the test's mock handler.
- `configureImageCache({int? physicalMemoryBytes})` — same optional-named shape in Task 5's Interfaces, code, and test.
- `PerfLog.init(String, {int payloadByteBudget})` — matches its one caller in Step 5.5.
- `AppState({… RetentionPolicy retention})` / `AppState.retentionPolicy` and `ImagePreloadController({… RetentionPolicy retention})` / `.retention` — the getter names differ between the two classes deliberately (`AppState.retentionPolicy` reads through to `_preloadController.retention`) and each is used under its own name at every site.
- Byte constants are the same three numbers everywhere: `234881024`, `318767104`, `402653184`; `304 * 1024 * 1024` and `384 * 1024 * 1024` in the implementation are those same values written in the form the file's neighbours use.
