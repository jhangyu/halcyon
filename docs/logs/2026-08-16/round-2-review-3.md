# Round 2 — Final narrow pass on the B3 fix (pass 3)

- Reviewed HEAD: `3cbc5ffa32e744d7a6520e258a83def9fd6e3e97`; scope `git diff bbde960 3cbc5ff` only (1339a25 + 3cbc5ff)
- **Tree state: CLEAN.** `git status --porcelain --untracked-files=no` empty at start and end of this pass. All evidence below was produced against the committed blobs at 3cbc5ff (the reviewed HEAD), not a dirty tree.
- New artifacts: `tmp/verify/r2/probe/{mutantB3.dart,mutantAF.dart,mREAL_test.dart,mB3_test.dart,mAF_test.dart,final_mutation_out.txt}`, `tmp/verify/r2/reviewer-flutter-test-3cbc5ff.txt`

## Verdict: 0 blockers. CLEARED.

## Q1 — is the conjunction complete, with no path where a pending entry reads ready?

**YES, verified by execution rather than by reading.** I did not re-run p3 as-is (it only probes ImageCache semantics, not the controller). Instead I ran a controller-level test that deterministically forces the pending state: pre-seed a never-completing `ImageStreamCompleter` under the exact tier-2 key for item 5, let the debounce fire (the controller's own resolve joins the seeded entry and never completes), then read readiness for item 5 (pending) and item 4 (same +-1 window, decoded normally). Against the shipped code at 3cbc5ff (`mREAL_test.dart`):

```
P4 pending_ready5=false completed_ready4=true
```

Pending reads false, completed reads true. The conjunction at `image_preload_controller.dart:109-118` is completion-flag AND key-exists AND identity AND containsKey, with the completion flag checked first. All four are pure map/set lookups — no resolve on the read path.

## Q2 — is the new test honest in both directions?

**YES, mutation-verified in both directions.** I built two mutants of the 3cbc5ff controller, each a single change, and ran the same test body against each (`final_mutation_out.txt`):

| Target | Output | Result |
|---|---|---|
| shipped 3cbc5ff | `pending_ready5=false completed_ready4=true` | passes |
| `mutantB3.dart` — the `:109` early return DELETED (i.e. the BLOCKER-3 code) | `pending_ready5=true` | FAILS on 'pending must read false' |
| `mutantAF.dart` — `isFullSizeReady` forced to always return false | `completed_ready4=false` | FAILS on 'completed must read true' |

Neither direction is vacuous: the first assertion catches a readiness that is too permissive, the second catches one that is too strict. This is exactly the bidirectional shape the B1 test lacked.

## Q3 — did this diff introduce anything new (the way the B1 fix introduced B3)?

**No. Nothing found.** Three angles checked:

**(a) What the early return changes for callers.** The only consumer chain is `AppState.currentItemHasFullSize` -> `main_detail_view.dart:203` (grepped; unchanged from the earlier pass). The added check can only make readiness FALSE more often, so the only possible new defect would be a false negative: the flag missing while a valid, resident entry for the current bytes exists. That cannot happen — `_tierTwoReadyIds` is mutated in exactly three places (`image_preload_controller.dart:265` add, inside the decode-completion listener; `:283` remove, inside `_evictTierTwoEntry`, which evicts the ImageCache entry in the same call; `:132` clear, inside `reset()`, which evicts first). Every removal is paired with an eviction, so there is no state in which the flag is absent while the entry it describes is still valid. A false negative would in any case be safe (display falls back to the resident tier-1 entry), unlike B3's false positive.

**(b) Does the early return skip anything with side effects?** No. It short-circuits before three pure lookups (`_tierTwoKeys[id]`, `_tierTwoBytes[id]`, `imageCache.containsKey`). `containsKey` does not touch LRU ordering, so skipping it cannot perturb eviction order either.

**(c) Can the pending-entry seeding leak into other tests?** No, on two independent grounds. First, the test registers `addTearDown(() => ic.evict(tierTwoKey))`, and `ImageCache.evict` removes the entry from `_liveImages` (disposing it), `_pendingImages` (with `removeListener`) and `_cache` (SDK image_cache.dart:244-262) — the SDK comment there explicitly covers the never-completing case. Second, even without teardown the key is a `MemoryImage` over a per-test-fresh `Uint8List`, and MemoryImage equality is bytes-object identity, so no other test can ever produce a colliding key. The controller's own listener on the never-completing stream is dropped with the controller; nothing global survives.

## Suite

My own run at 3cbc5ff (`tmp/verify/r2/reviewer-flutter-test-3cbc5ff.txt`, first line is the hash): exit 0, "All tests passed!", 23 executed == 23 declared (10 preload + 6 app_state + 3 photo_item + 2 photo_file_actions + 1 main + 1 widget). No test skipped, weakened, or deleted by this diff; the new test wraps its body in `tester.runAsync`.

## Comment accuracy (N1, second pass)

`main_detail_view.dart:196-204` and the doc comment at `image_preload_controller.dart:87-107` now state the completion requirement explicitly and no longer claim "resident" where "pending" is possible. Both match the code as executed.

## Not verified / still parked

- AC7/AC8 (WP5's measurement and post-merge gate) — untouched by this pass.
- Parked and not re-examined, per instruction: S5, S3, S4, N2, N3, tier-1 side of `reset()`, the two earlier WP2 items.

