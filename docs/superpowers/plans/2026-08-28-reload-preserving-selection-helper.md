# Reload-Preserving-Selection Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use podium:team-spawn (recommended) or podium:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the "reload the mutated folder and restore the selection" contract one owner — a private `AppState._reloadPreservingSelection(Directory dir)` used by both `processStarred` and `deleteTrashed`.

**Architecture:** Pure in-file refactor of `lib/providers/app_state.dart`. One new private method wraps the existing `loadFolder(dir, targetSelectionId:, targetFallbackIndex:)` call; both batch-action methods drop their duplicated selection-capture locals and call it. `loadFolder`'s four-branch restore logic is untouched. One characterization test (`TC-248`) pins the restored-selection behaviour, proven red by a temporary mutation before the refactor lands.

**Tech Stack:** Flutter 3.35 / Dart 3, `flutter_test`.

**Spec:** `docs/logs/2026-08-28/spec-reload-preserving-selection-helper.md`

## Global Constraints

- One private helper only — no new class, interface, file, or public `AppState` member.
- `loadFolder` (`lib/providers/app_state.dart:272-328`) must not be modified.
- `lib/services/library/photo_file_actions.dart`, `lib/views/**`, and all config files must not be modified.
- Drift resolution (frozen by the spec): the reload directory is **captured before the file mutation** in both callers; the selection values are captured **inside the helper at call time**.
- `flutter analyze` must report `No issues found!` before the work is considered done.
- Shared tree: commit with an explicit pathspec (`git commit -- <paths>`); never `git stash/reset/checkout --/clean`.

---

### Task 1: Extract `_reloadPreservingSelection` and pin it with TC-248

**Files:**
- Modify: `lib/providers/app_state.dart:441-474` (`processStarred`), `lib/providers/app_state.dart:498-538` (`deleteTrashed`), plus the new helper inserted immediately above `processStarred` (after `preloadThumbnails`, `:438`).
- Test: `test/providers/app_state_test.dart` (new test `TC-248` inside the existing `group('AppState.loadFolder', ...)`… place it instead in a new `group('AppState.processStarred selection restore', ...)` appended after the `AppState recycle mode` group at `:470`).
- Modify: `docs/sop/unit_test.md` (add the `TC-248` matrix row).

**Interfaces:**
- Consumes: `AppState.loadFolder(Directory dir, {String? targetSelectionId, int? targetFallbackIndex})`; fields `_items` (`List<PhotoItem>`), `_selectedItemID` (`String?`), `_currentDir` (`Directory?`).
- Produces: `Future<void> _reloadPreservingSelection(Directory dir)` — private to `AppState`, no other task consumes it.

**Behavior:**
The helper reads `_selectedItemID` and the index of that id in `_items` at call time, then delegates to `loadFolder` with those as `targetSelectionId` / `targetFallbackIndex`. Call-time capture is safe because `PhotoFileActions` mutates the filesystem only and never touches `_items` or `_selectedItemID` (`lib/services/library/photo_file_actions.dart:50-109`); the helper's doc comment records this dependency. When nothing is selected, `_selectedItemID` is `null` and `indexWhere` returns `-1`; `loadFolder` then finds no matching id and no in-range fallback index, so it falls through to `lastViewedId` → first item — identical to today.

`processStarred` changes semantics in exactly one way: it captures `final dir = _currentDir;` before the file operation instead of re-reading `_currentDir` after it, matching `deleteTrashed`. `deleteTrashed` keeps its existing `dir` capture at `:501` and only swaps its reload block for the helper call. Neither method's error handling, status messages, nor `BatchDeleteResult` construction changes.

**Constraints:**
- Net effect must be a shrink: the two capture prologues (`:444-445`, `:499-500`) lose their `currentId`/`currentIndex` locals and the two 5-line reload blocks collapse to one line each.
- No behavioural change beyond the frozen drift resolution.
- No new imports.

**Acceptance criteria:**
- [ ] `grep -c "_reloadPreservingSelection" lib/providers/app_state.dart` → `3`
- [ ] `grep -c "targetFallbackIndex:" lib/providers/app_state.dart` → `1` (was `2`)
- [ ] `grep -c "indexWhere((i) => i.id ==" lib/providers/app_state.dart` → `1` (was `2`)
- [ ] `grep -c "currentIndex" lib/providers/app_state.dart` → `0`
- [ ] `flutter analyze` → `No issues found!`
- [ ] `flutter test test/providers/app_state_test.dart` → exit code 0, `All tests passed!`
- [ ] `flutter test` → exit code 0, `All tests passed!`
- [ ] `grep -c "TC-248" test/providers/app_state_test.dart` → `1`; `grep -c "TC-248" docs/sop/unit_test.md` → `2` (section heading + 測試 ID row)

**Steps:**

- [ ] **Step 1: Write the characterization test**

Append this group to `test/providers/app_state_test.dart`, immediately after the closing `});` of `group('AppState recycle mode', ...)` (`:470`):

```dart
  group('AppState.processStarred selection restore', () {
    test('TC-248 keeps the selected photo, falling back to its index',
        () async {
      final src = await Directory.systemTemp.createTemp('halcyon_ps248_src_');
      addTearDown(() => src.delete(recursive: true));
      final dest = await Directory.systemTemp.createTemp('halcyon_ps248_dst_');
      addTearDown(() => dest.delete(recursive: true));
      await _touch(src, 'IMG_0001.jpg');
      await _touch(src, 'IMG_0002.jpg');
      await _touch(src, 'IMG_0003.jpg');

      final state = _testState();
      addTearDown(state.dispose);
      await state.loadFolder(src);

      // Star IMG_0001, then park the selection on IMG_0002: the selected
      // photo survives the move, so it must still be selected afterwards.
      state.selectItem('IMG_0001');
      state.markCurrent(PhotoStatus.starred);
      state.selectItem('IMG_0002');

      await state.processStarred(dest.path, true);

      expect(state.items.map((item) => item.id), ['IMG_0002', 'IMG_0003']);
      expect(state.selectedItemID, 'IMG_0002',
          reason: 'surviving selection is restored by id');

      // Now star and move the SELECTED photo. Its id is gone from the new
      // scan, so the restore falls to the captured index: IMG_0002 sat at
      // index 0, and index 0 of the reloaded ['IMG_0003'] is IMG_0003.
      state.markCurrent(PhotoStatus.starred); // IMG_0002 is current
      await state.processStarred(dest.path, true);

      expect(state.items.map((item) => item.id), ['IMG_0003']);
      expect(state.selectedItemID, 'IMG_0003',
          reason: 'vanished selection falls back down the loadFolder chain');
    });
  });
```

- [ ] **Step 2: Run it against unmodified `lib/` to record the baseline**

Run: `flutter test test/providers/app_state_test.dart -j 1 --plain-name "TC-248"; echo RC=$?`
Expected: `All tests passed!`, `RC=0`. This is a characterization test — it must pass **before** the refactor, because the refactor is behaviour-preserving.

- [ ] **Step 3: Prove the test is not vacuous (mutation red step)**

Temporarily change `lib/providers/app_state.dart:470` from `targetSelectionId: currentId,` to `targetSelectionId: null,`.

Run: `flutter test test/providers/app_state_test.dart -j 1 --plain-name "TC-248"; echo RC=$?`
Expected: FAIL on the first `expect(state.selectedItemID, 'IMG_0002')` with `Expected: 'IMG_0002' Actual: 'IMG_0003'` — without the id, the restore uses the captured index 1, which now points at IMG_0003. `RC=1`.

Then restore the line to `targetSelectionId: currentId,` and re-run the same command: `All tests passed!`, `RC=0`. Do not commit the mutation.

- [ ] **Step 4: Add the helper**

Insert immediately after `preloadThumbnails` (ends `lib/providers/app_state.dart:438`) and before the `// Actions` comment:

```dart
  /// Reloads [dir] and puts the selection back where it was.
  ///
  /// Call this *after* a batch file operation. `PhotoFileActions` touches the
  /// filesystem only — it never mutates [_items] or `_selectedItemID` — so the
  /// selection read here is still the pre-operation one. [dir] must be the
  /// directory captured before the operation, not `_currentDir` re-read now:
  /// the folder to refresh is the folder that was mutated.
  Future<void> _reloadPreservingSelection(Directory dir) {
    final currentId = _selectedItemID;
    return loadFolder(
      dir,
      targetSelectionId: currentId,
      targetFallbackIndex: _items.indexWhere((i) => i.id == currentId),
    );
  }
```

- [ ] **Step 5: Rewrite `processStarred`**

Replace `lib/providers/app_state.dart:441-474` with:

```dart
  Future<void> processStarred(String destinationStr, bool move) async {
    final destDir = Directory(destinationStr);
    final dir = _currentDir;

    try {
      final outcome = await _fileActions.processStarred(
        _items,
        destDir,
        move: move,
        overwriteExisting: _overwriteExisting,
      );
      if (outcome.failures.isNotEmpty) {
        // Previously debugPrint only, so a read-only destination or a
        // permission-denied copy looked identical to a working app.
        for (final failure in outcome.failures.take(3)) {
          debugPrint('processStarred failure: $failure');
        }
        showStatus(StatusMessage('*${outcome.failures.length}* 個檔案處理失敗'));
      }
    } catch (e) {
      debugPrint("Error processing starred items: $e");
      showStatus(StatusMessage('檔案處理失敗：$e'));
    }

    if (dir != null) {
      await _reloadPreservingSelection(dir);
    }
  }
```

- [ ] **Step 6: Rewrite `deleteTrashed`'s prologue and reload block**

In `lib/providers/app_state.dart:498-530`, delete the two capture lines

```dart
    final currentId = _selectedItemID;
    final currentIndex = _items.indexWhere((i) => i.id == currentId);
```

so the method now opens with

```dart
  Future<BatchDeleteResult> deleteTrashed() async {
    final dir = _currentDir;
    final recycled = _recycleMode;
```

and replace the reload block with

```dart
    if (dir != null) {
      await _reloadPreservingSelection(dir);
    }
```

Leave the `BatchDeleteResult` return untouched.

- [ ] **Step 7: Run the mechanical checks**

Run:
```bash
grep -c "_reloadPreservingSelection" lib/providers/app_state.dart   # 3
grep -c "targetFallbackIndex:" lib/providers/app_state.dart         # 1
grep -c "indexWhere((i) => i.id ==" lib/providers/app_state.dart    # 1
grep -c "currentIndex" lib/providers/app_state.dart                 # 0
flutter analyze; echo RC=$?
```
Expected: the four counts above, then `No issues found!` and `RC=0`.

- [ ] **Step 8: Run the tests**

Run: `flutter test test/providers/app_state_test.dart -j 1; echo RC=$?`
Expected: `All tests passed!`, `RC=0`, and the declared test count equals the executed count.

Run: `flutter test -j 1; echo RC=$?`
Expected: `All tests passed!`, `RC=0`.

- [ ] **Step 9: Record TC-248 in the test matrix**

`docs/sop/unit_test.md` uses one `###` section plus a table per test case (see the TC-247 block at `docs/sop/unit_test.md:400-409`). Insert this block immediately above that TC-247 section, keeping the surrounding `---` separators:

```markdown
### TC-248｜AppState — 批次檔案操作後的「重載並保留選取」契約單一擁有者（refactor proposal 1）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-248 |
| **名稱** | 移動星標檔後，若原選取照片仍在資料夾中，選取維持在同一張（id 分支）；若被移走的正是選取的照片，選取沿 `loadFolder` 的回退鏈落到原索引位置的照片（index 分支） |
| **測試類型** | 單元測試（真實暫存資料夾 + 假 `NativeImageLoad`，直接驅動 `AppState.processStarred`） |
| **驗證方式** | `test/providers/app_state_test.dart` 的 `group('AppState.processStarred selection restore')`（1 個測試案例） |
| **狀態** | ✅ 已通過 |
| **依據** | `AppState.processStarred`／`deleteTrashed` 的重載尾段抽成私有 `_reloadPreservingSelection`，選取值改在該 helper 內於呼叫時讀取；本案釘住這個行為不因抽取而改變 |
```

- [ ] **Step 10: Commit**

```bash
git add lib/providers/app_state.dart test/providers/app_state_test.dart docs/sop/unit_test.md
git commit -- lib/providers/app_state.dart test/providers/app_state_test.dart docs/sop/unit_test.md -m "refactor(app_state): single owner for reload-preserving-selection"
git status --porcelain   # expect no leftover staged changes from this task
```

---

## Self-Review (run by the plan author)

**1. Spec coverage.** Spec sections map as follows: helper extraction → Task 1 Steps 4-6; drift resolution (dir captured up front) → Step 5 plus Global Constraints; call-time selection capture + documented invariant → Step 4's doc comment; TC-248 → Steps 1-3; `docs/sop/unit_test.md` row → Step 9; spec acceptance criteria 1-9 → Task 1 acceptance criteria + Steps 7-8. Spec AC 4 ("no new public member") is covered implicitly by the constraint "no public `AppState` member" and the complete code shown — no separate grep step; that is the only softened item. No spec requirement lacks a step.

**2. Placeholder scan.** No "TBD"/"TODO"/"similar to Task N"/"add error handling" strings. Every code step shows complete code; every command step shows the exact command and expected output.

**3. Type consistency.** `_reloadPreservingSelection(Directory dir) -> Future<void>` is used identically in both callers (`await _reloadPreservingSelection(dir);`), and its `loadFolder` arguments match that method's declared signature (`String? targetSelectionId`, `int? targetFallbackIndex`) at `lib/providers/app_state.dart:272-276`. `dir` is `Directory?` at both call sites and is null-guarded before the call.
