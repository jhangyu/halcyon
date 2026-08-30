# D1 Root-cause report: tier-2 full-size upgrade never reaches the widget

Author: debugger-tier2-opus (task #1) — 2026-08-30
Status: root cause CONFIRMED (mechanical evidence below). No fix implemented.

## Verdict in one sentence

Tier-2 fires correctly and lands in ImageCache on time; the **display path throws it
away**, because `TierTwoRegistry.fullResProviderFor` filters the tier-2 key with
`key is RawFullResImage` and an encoded-payload item's key is a `MemoryImage`, so the
view falls back to the window-resolution tier-1 provider forever.

This is hypothesis **(b)** (provider swap never reaches the widget), *unmasked* by
hypothesis **(d)**: Phase 13's re-encode moved RAW items from the `PixelPayload`
family into the `EncodedPayload` family, which is precisely the family the display
getter refuses to serve. Hypotheses (a) lane starvation and (c) debounce reset are
NOT the cause — see "Falsified" below.

## Causal chain (file:line)

1. Production wires the native JPEG encoder on by default:
   `lib/services/image_pipeline/image_preload_controller.dart:104`
   (`PayloadEncoder? payloadEncoder = _encodeJpegNative`) → `:110` into `PhotoSource`.
2. An expensive RAW decode therefore returns an **`EncodedPayload`**, not a
   `PixelPayload`: `lib/services/image_pipeline/photo_source.dart:316-322` calls
   `reencodePayload(...)`, which returns `EncodedPayload(jpeg)` at
   `lib/services/image_pipeline/payload_reencoder.dart:120`. The bytes are genuinely
   full resolution (`_fullResFrom` uses `longEdge: 0`,
   `photo_source.dart:355-365`) — so the *data* is right.
3. After the 250ms debounce, `TierTwoScheduler._decodeWindow` takes the
   `EncodedPayload()` branch at
   `lib/services/image_pipeline/tier_two_scheduler.dart:255-263` and calls
   `_registry.publishEncoded(...)` with `fullSizeProviderFor(bytes)` =
   `MemoryImage(bytes)` (`image_preload_controller.dart:69`, `:1120`).
   **This is correct and it works.**
4. `TierTwoRegistry.publishEncoded` records `_keys[id] = <MemoryImage key>` and sets
   `_readyIds` when the decode listener fires:
   `lib/services/image_pipeline/tier_two_registry.dart:145-163`.
   `isReady(id)` → **true**.
5. The view asks for the provider through
   `AppState.displayProvider` (`lib/providers/app_state.dart:258-259`):
   `currentItemHasFullSize ? currentFullResProvider : currentDecodedProvider`.
   - `currentItemHasFullSize` → `isReady` → **true** (step 4).
   - `currentFullResProvider` → `image_preload_controller.dart:322` →
     `tier_two_registry.dart:99-103`:
     ```dart
     ImageProvider? fullResProviderFor(String id) {
       if (!isReady(id)) return null;
       final key = _keys[id];
       return key is RawFullResImage ? key : null;   // <-- MemoryImage => null
     }
     ```
     → **null**.
6. `main_detail_view.dart:275-277` then falls back:
   `provider = pixelProvider ?? tierOneProviderFor(bytes!, width: targetWidth, height: targetHeight)`
   — the **window-resolution** provider. Worse, `main_detail_view.dart:280`
   sets `isFullResolution = useFullSize` (= true), so the perf instrumentation
   labels this frame "tier 2" while painting tier 1. Any log-based check of the
   upgrade reports success.

Net: dwell forever, the preview stays at window resolution. Exactly the symptom.

## When it broke

`dd32323` (2026-08-25, "refactor(views): single display provider"). The removed code
had an explicit encoded-family tier-2 branch:

```dart
final ImageProvider provider = decodedProvider != null
    ? (fullResProvider ?? decodedProvider)
    : (useFullSize ? fullSizeProviderFor(bytes!)        // <-- DELETED
                   : tierOneProviderFor(bytes!, ...));
```

The refactor routed both families through `currentFullResProvider`, but that getter
only ever served the pixel family. The comment left behind at
`main_detail_view.dart:264-266` asserts the opposite of the code:
"AppState.currentFullResProvider covers encoded payloads too, not just decoded-pixel
ones" — it does not.

Since `dd32323` this silently killed the tier-2 swap for plain JPG items too. It only
became *user-visible on RAW* when Phase 13's re-encoder moved RAWs into the encoded
family, which is why it reads as a new bug.

## Mechanical evidence

Temporary probe test (`test/services/image_pipeline/tmp_tier2_rootcause_probe_test.dart`,
to be deleted after sign-off), artifact `tmp/tier2-probe.txt`, `RC=0`:

```
00:00 +1: All tests passed!
RC=0
```

The passing assertions ARE the bug (the test asserts current, broken behaviour):

| assertion | result |
|---|---|
| `registry.isReady('a')` | `true`  — AppState.currentItemHasFullSize is true |
| `registry.fullResProviderFor('a')` | `null` — the view gets nothing to paint |
| `identical(registry.providerFor('a'), provider)` | `true` — the correct tier-2 object exists, behind the wrong getter |

## Why the test suite is green

`test/services/image_pipeline/image_preload_reencode_tier_two_test.dart:169` verifies
the re-encode tier-2 entry through `controller.debugTierTwoProviderFor(...)` — the
**unfiltered** `TierTwoRegistry.providerFor` (`tier_two_registry.dart:111-114`). No
test asserts the *display-path* getter (`fullResProviderFor` /
`AppState.displayProvider`) for an `EncodedPayload` item. The pipeline is tested
through a different door than the one the widget uses.

## Falsified hypotheses (negative results)

- **(a) lane width 2 starved by sidebar decodes** — falsified as the *cause*. The
  encoded branch at `tier_two_scheduler.dart:255-263` is `publishEncoded`, taken
  **synchronously inside `_decodeWindow`**; it never touches `DecodeLane`. Lane
  pressure cannot delay it, and D2's `laneCeiling=2` is irrelevant to this symptom.
  (It remains a real, separate perf issue.)
- **(c) debounce reset by unrelated notifications** — falsified. `schedule()`
  (`tier_two_scheduler.dart:173-182`) is the only arming site and only navigation
  passes call it; and the probe shows the entry does reach `isReady == true`, i.e.
  the debounce did fire and the decode did complete.
- **(d) tier-2 receives downscaled bytes** — falsified as stated. `_fullResFrom`
  uses `longEdge: 0` (`photo_source.dart:355-365`) and `reencodePayload` refuses to
  encode the window-resolution fallback (`payload_reencoder.dart:110-116`). The
  bytes are full resolution. (d) is only the *trigger* that exposed (b).

## Minimal fix proposal (for the sonnet fixer — do not treat as implemented)

Smallest correct change: make the display-path getter serve both tier-2 families,
since every tier-2 key already IS its own provider.

In `lib/services/image_pipeline/tier_two_registry.dart:99-103`:

```dart
ImageProvider? fullResProviderFor(String id) {
  if (!isReady(id)) return null;
  return providerFor(id);   // any resident tier-2 key; both families are providers
}
```

Notes for the fixer:
- Object identity is preserved — `providerFor` returns `_keys[id]`, the very object
  registered as the ImageCache key, so resolving it at the display site stays a cache
  hit (invariant I1 / design §2.3 unaffected). No provider is constructed.
- `RawFullResImage`'s one-shot property is untouched: the same object is handed out,
  not rebuilt.
- Fix the now-false doc comments at `tier_two_registry.dart:99`,
  `image_preload_controller.dart:313-321` (both say "for a pixel-backed item").
- `main_detail_view.dart:264-266`'s comment becomes true after this change; no view
  edit is required.
- Red→green evidence must use the **display-path** getter, not
  `debugTierTwoProviderFor`: assert `fullResProviderFor` returns the published
  `MemoryImage` for an `EncodedPayload` item. Register it in `unit_test.md`
  (new TC-NNN, take the next free number and reconcile at merge — see
  lessons-learned 2026-08-28 on shared registries).
- Delete `test/services/image_pipeline/tmp_tier2_rootcause_probe_test.dart`
  (it asserts the broken behaviour and will go red once fixed — that is the
  red→green signal; capture its failure output first, then delete).
- Suggested `memory.md` gotcha: "a tier-2 getter that filters by provider TYPE
  silently drops a whole payload family; the tests reached tier-2 through a
  debug-only getter, so the display path had zero coverage."
