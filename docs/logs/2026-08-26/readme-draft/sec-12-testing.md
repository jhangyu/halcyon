## Testing and quality gates

```bash
flutter analyze                                   # must report 0 issues
flutter test                                      # full suite
flutter test test/providers/app_state_test.dart   # a single file
flutter test --coverage
```

The suite is 45 test files under `test/`, organised to mirror `lib/`: `models/`,
`providers/`, `services/`, `views/`, `perf/`, plus shared fakes in `test/support/`. Each
test carries a 10-second timeout.

<!-- evidence: dart_test.yaml:1, test/ directory listing 2026-08-26 -->

`flutter analyze` reporting zero issues is a gate, not a preference — work is not
considered done while it reports anything. Note that analysis covers `lib/`, `test/` **and**
`tool/`, so a symbol rename that only sweeps `lib/` and `test/` will still break the gate.

<!-- evidence: CLAUDE.md Commands section; memory.md 2026-08-25 naming-refactor entry -->

### What makes the suite possible

`AppState` receives every collaborator through its constructor — the library scanner, the
status store, the file actions, the preload controller, the image-loading function and the
optional full decoder. Tests substitute fakes for all of them, so the application logic is
exercised without touching the filesystem or a platform channel. The decoder seam is the
same story: the pipeline is tested against a fake decoder rather than by loading the real
native library.

<!-- evidence: lib/providers/app_state.dart constructor; lib/services/image_pipeline/dng_decode_contract.dart -->

### Test strategy documentation

`unit_test.md` holds the test strategy, the TC-NNN test-case matrix with per-case pass/fail
history, and the coverage priorities. Any test added to this repository is expected to get a
corresponding entry in that matrix. It also records cases that were attempted and
deliberately dropped — for example a full keyboard widget test that hung the test runner's
timers — which is worth reading before re-attempting one.

<!-- evidence: unit_test.md:1-3, unit_test.md:197 -->

### Known testing hazards

Two traps in this codebase have cost real time and are documented in `memory.md`:

- A `testWidgets` body that performs real `dart:io` work must be wrapped in
  `tester.runAsync`, and awaiting a real engine future inside `FakeAsync` hangs forever.
- Tapping a `PopupMenuItem` inside `testWidgets` hangs under `FakeAsync`.

<!-- evidence: memory.md G-020, memory.md G-013 -->
