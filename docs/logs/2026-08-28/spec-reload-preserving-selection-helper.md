# Spec — extract `_reloadPreservingSelection` in `AppState`

Date: 2026-08-28 · HEAD at time of writing: `e664ff9`
Source review: `docs/logs/2026-08-28/refactor-review-report.md` (Proposal 1),
`docs/logs/2026-08-28/refactor-review-coupling.md` (Finding 1).

## Goal

Give the contract *"after a destructive batch operation, reload the folder that
was mutated and land the selection back on the same photo — or on its old index
if the photo is gone"* a single owner: one private method on `AppState`, used by
both `processStarred` and `deleteTrashed`. Observable behaviour is unchanged
except for one deliberate drift resolution (below).

## In scope

- Add one private method `Future<void> _reloadPreservingSelection(Directory dir)`
  to `lib/providers/app_state.dart`.
- Rewrite the capture prologue + reload epilogue of `AppState.processStarred`
  and `AppState.deleteTrashed` to use it.
- One new regression test pinning the restored-selection contract for the
  `processStarred` path (`TC-248`), plus its `docs/sop/unit_test.md` matrix row.

## Out of scope

- Any change to `loadFolder`'s four-branch selection-restore logic
  (`lib/providers/app_state.dart:300-316`).
- New classes, interfaces, files, or a public API on `AppState`.
- Any change to `PhotoFileActions`, the views, or the export path.
- Guarding against a concurrent `loadFolder`/`openPhotoAtPath` racing a batch
  operation (see Risks — no such call path exists today).

## Current behaviour (evidence at HEAD `e664ff9`)

`AppState.processStarred` (`lib/providers/app_state.dart:441-474`):

- `:444-445` — captures `currentId = _selectedItemID` and
  `currentIndex = _items.indexWhere((i) => i.id == currentId)` **before**
  mutating files.
- `:447-465` — mutates via `_fileActions.processStarred(...)`, reports failures
  on the status line.
- `:467-473` — `if (_currentDir != null) await loadFolder(_currentDir!,
  targetSelectionId: currentId, targetFallbackIndex: currentIndex);`
  → **reads `_currentDir` at reload time.**

`AppState.deleteTrashed` (`lib/providers/app_state.dart:498-538`):

- `:499-500` — identical capture of `currentId` / `currentIndex`.
- `:501-502` — additionally captures `final dir = _currentDir;` and
  `final recycled = _recycleMode;` **up front** (the `.trash` path at `:510`
  and the recycle branch at `:509` both need `dir`).
- `:524-530` — `if (dir != null) await loadFolder(dir, targetSelectionId:
  currentId, targetFallbackIndex: currentIndex);`
  → **uses the directory captured before the mutation.**

Both then rely on `loadFolder`'s restore order (`:300-316`):
`targetSelectionId` present in the new scan → `targetFallbackIndex` in range →
persisted `lastViewedId` → last item (when a fallback index was given but is out
of range) → first item.

Verified invariant (relied on by the design below): neither
`PhotoFileActions.processStarred` (`lib/services/library/photo_file_actions.dart:50-86`),
`.deleteTrashed` (`:89-109`) nor `.recycleTrashed` mutates the `List<PhotoItem>`
it is handed — they only touch the filesystem and read `item.status`/`item.files`.
`AppState._items` and `AppState._selectedItemID` are therefore identical before
and after the file operation; only `loadFolder` replaces them.

Existing test coverage of these two paths in `test/providers/app_state_test.dart`:

- `TC-221 a failing copy surfaces a status message` (`:251-272`) — drives
  `processStarred` end to end including the reload.
- `recycle mode moves files to .trash instead of the system trash` (`:411-443`)
  — drives `deleteTrashed`, asserts `state.items` is empty *"folder reloaded
  after recycle"*.
- `direct mode still routes through the system trash` (`:445-469`) — the
  non-recycle `deleteTrashed` branch.

## Drift resolution (the decision this spec must make)

**Chosen semantic: capture the directory up front — `deleteTrashed`'s form wins;
`processStarred` changes to match.**

Justification:

1. The reload exists to refresh *the folder whose files were just mutated*. The
   directory that was mutated is the one that was current when the operation
   started, so it is the correct value to reload — reading `_currentDir` after
   the `await` re-derives it from state that is, in principle, free to move.
2. `deleteTrashed` cannot adopt the other semantic: it already needs `dir` up
   front for the `.trash` path (`:510`) and the recycle branch (`:509`). Making
   the helper read `_currentDir` internally would force `deleteTrashed` to keep
   two different notions of "the directory", which is exactly the drift being
   removed.
3. Today the two forms are observationally identical — no code path mutates
   `_currentDir` while a batch operation is in flight (both are invoked only
   from `lib/views/sidebar_view.dart:338` and `:348`, awaited from UI
   callbacks). So this is a free tightening, not a behaviour change users can see.

The selection values (`currentId` / `currentIndex`), by contrast, are captured
**inside** the helper at call time. Given the verified invariant above,
call-time capture yields byte-identical arguments to the up-front capture, and
it removes two locals per caller. The helper carries a doc comment stating the
invariant it depends on, and `TC-248` pins it.

## Proposed design

```dart
/// Reloads [dir] and puts the selection back where it was.
///
/// Call this *after* a batch file operation: `PhotoFileActions` mutates the
/// filesystem only — it never touches [_items] or [_selectedItemID] — so the
/// selection read here is still the pre-operation one. [dir] must be the
/// directory captured before the operation, not `_currentDir` re-read now.
Future<void> _reloadPreservingSelection(Directory dir) {
  final currentId = _selectedItemID;
  return loadFolder(
    dir,
    targetSelectionId: currentId,
    targetFallbackIndex: _items.indexWhere((i) => i.id == currentId),
  );
}
```

Callers become:

```dart
// processStarred — dir captured before the mutation
final dir = _currentDir;
...
if (dir != null) await _reloadPreservingSelection(dir);

// deleteTrashed — dir already captured at :501
if (dir != null) await _reloadPreservingSelection(dir);
```

## Acceptance criteria

1. `grep -c "targetFallbackIndex:" lib/providers/app_state.dart` returns `1`
   (only the helper passes it; `loadFolder`'s own parameter declaration uses
   `int? targetFallbackIndex,` without the colon-space form).
2. `grep -n "_reloadPreservingSelection" lib/providers/app_state.dart` shows
   exactly three hits: one declaration, one call in `processStarred`, one call
   in `deleteTrashed`.
3. `indexWhere((i) => i.id ==` appears exactly once in
   `lib/providers/app_state.dart`.
4. `AppState` gains no new public member: every method/getter name added by
   `git diff -- lib/providers/app_state.dart` starts with `_`
   (`git diff -U0 -- lib/providers/app_state.dart | grep '^+' | grep -E '^\+\s+(Future|void|String|int|bool|Directory)[^ ]* [A-Za-z]'`
   returns nothing).
5. `flutter analyze` → `No issues found!`.
6. `flutter test test/providers/app_state_test.dart` → all tests pass, declared
   count == executed count, exit code 0.
7. `flutter test` (full suite) → exit code 0, `All tests passed!`.
8. New test `TC-248` exists in `test/providers/app_state_test.dart`, fails
   before the refactor's helper is wired in a way that drops the selection
   (verified by the red step in the plan), and passes after.
9. `docs/sop/unit_test.md` contains a `TC-248` row.

## Risks

- **Low — behaviour drift on the `processStarred` reload directory.** Only
  observable if `_currentDir` changes during the awaited file operation; no such
  call path exists (both entry points are `await`ed UI callbacks). Mitigation:
  the change is explicitly documented here and in the helper's doc comment.
- **Low — the call-time selection capture depends on `PhotoFileActions` never
  mutating `_items`.** Mitigation: doc comment states it; `TC-248` fails loudly
  if a future change breaks it.
- **Negligible — regression in the four-branch restore order**, since
  `loadFolder` is untouched and the arguments are unchanged.
