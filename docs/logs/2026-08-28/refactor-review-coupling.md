# Coupling / Duplication Review — 2026-08-28

Scope: (a) excessive coupling / god-object growth in `AppState`; (b) the same
functionality implemented in multiple places that should be consolidated.
Reviewed at current HEAD. Analysis only — no source changes.

## Verdict

The codebase is already strongly decomposed and its coupling is actively
managed, so the bar for "worth changing" is high. I found **one** genuine,
low-risk duplication worth naming and **one** concern that is explicitly out
of bounds because reversing it would undo a recorded, deliberate decision.

---

## Finding 1 (LOW–MODERATE value) — the "act, then reload preserving selection" dance is duplicated verbatim

**Evidence.** Two batch-action methods on `AppState` open with the identical
selection-capture prologue and close with the identical reload epilogue:

- `processStarred` — `lib/providers/app_state.dart:444-445` capture, `467-473` reload
- `deleteTrashed`  — `lib/providers/app_state.dart:499-500` capture, `524-530` reload

Both do:

```dart
final currentId = _selectedItemID;
final currentIndex = _items.indexWhere((i) => i.id == currentId);
// ... mutate files via _fileActions ...
if (dir != null) {
  await loadFolder(dir, targetSelectionId: currentId, targetFallbackIndex: currentIndex);
}
```

**Cost it imposes.** The contract "after a destructive batch op, reload the
folder and land the selection back on the same photo (or its index if the photo
is gone)" is implemented twice with no single owner. `loadFolder`'s
selection-restore logic (`app_state.dart:300-316`) is subtle — it has a
four-branch fallback order (targetSelectionId → targetFallbackIndex →
lastViewedId → last → first). Any future change to how selection survives a
reload has to be kept in sync across two call sites that already drifted once
in their error handling. This is a real (not speculative) coupling: the two
methods are silently coupled through the exact argument shape they must pass.

**Minimal decoupling sketch.** Extract one private helper on `AppState`, no new
type, no new file:

```dart
Future<void> _reloadPreservingSelection(Directory dir) {
  return loadFolder(
    dir,
    targetSelectionId: _selectedItemID,
    targetFallbackIndex: _items.indexWhere((i) => i.id == _selectedItemID),
  );
}
```

Both methods capture `currentId`/`currentIndex` *before* mutating, so the
helper must be called with the pre-mutation values — either capture them as
locals and pass them in, or (simpler) have the helper capture at call time
since `_items`/`_selectedItemID` are not yet re-read until after the file op
returns. Net removal ≈ 6 duplicated lines and a single owner for the reload
contract.

**Effort.** ~15 minutes including running `flutter test` (the app_state suite
already exercises both paths). Trivial and low-risk.

**Honest caveat.** This is close to the "don't nitpick trivial low-benefit
details" line. It clears the bar only because the duplicated logic is a
non-obvious multi-branch contract, not because the line count is large. If the
team prefers zero churn, skipping it is defensible.

---

## Explicitly NOT proposed — `AppState` as a god object

`AppState` is 584 lines and is the single `ChangeNotifier` coordination point,
which superficially reads as god-object growth. It is not, and proposing to
break it up would reverse recorded, deliberate decisions:

- **AD-005** collapsed `AppState` into a *UI-state coordination layer* on
  purpose, pushing scanning / status JSON / preload+cache / file actions into
  `PhotoLibraryScanner`, `PhotoStatusStore`, `ImagePreloadController`,
  `PhotoFileActions` (all constructor-injected — `app_state.dart:62-104`).
- **AD-015** moved all zoom/animation state out to `ZoomController`.
- **AD-026** moved the rename domain out to `RenameCoordinator`; `AppState` now
  holds only thin forwarders (`app_state.dart:114-116, 540-576`).

What remains in `AppState` is genuinely coordination: selection/navigation,
settings persistence, status-line state, and delegation to the injected
collaborators. Testability is already achieved via the fakes that
constructor injection enables (per the CLAUDE.md architecture note). There is
no untestable knot here to cut, and no collaborator is doing another's job.
`readMetadataFor` (`app_state.dart:547-569`) is the one method that is arguably
mis-homed (EXIF plumbing living on the coordinator), but it is passed as a
supplier callback into `RenameCoordinator` (`app_state.dart:97`) and is also
consumed directly by the rename dialog's preview, so its current placement is
the least-coupled home for a shared reader. Not worth moving.
