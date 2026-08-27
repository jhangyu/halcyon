# Refactor Review — Reference Architecture Comparison

Task #5 · refactor-impl-2-sonnet · 2026-08-28 · analysis only

## Verdict

**no improvement worth making**

## What was compared

Halcyon's actual architecture (grounded in `lib/CLAUDE.md`, the `lib/` tree, and
`lib/providers/app_state.dart`) against strong reference architectures for
image-heavy Flutter/desktop apps:

- **Aves** (github.com/deckerst/aves) — the most respected open-source Flutter
  gallery. Widget-based, modular packages, relies on Flutter's built-in image
  cache rather than a heavyweight state framework; state is plain
  `ChangeNotifier`/`Listenable`-class holders, not bloc/riverpod.
- **Flutter official app-architecture guide**
  (https://docs.flutter.dev/app-architecture/guide) — the current canonical
  reference: UI layer (views + view models) over a data layer (repositories +
  services), with an optional domain layer only when business logic grows. The
  state holder "may be a BLoC, ChangeNotifier, Riverpod Notifier, or ordinary
  Dart class" — the guide is explicit that the package choice is orthogonal to
  the architecture.
- **Code With Andrea / Riverpod four-layer reference**
  (https://codewithandrea.com/articles/flutter-app-architecture-riverpod-introduction/)
  — the popular Riverpod-based layered architecture.

## Why Halcyon already lands in the right place for its size

1. **It already implements the official UI→data layering.** `views/` →
   `AppState` (view-model / coordination point) → `services/` (repository-style:
   `PhotoLibraryScanner`, `PhotoStatusStore`, `PhotoFileActions`,
   `PhotoExportService`, `image_pipeline/…`) → `models/`. This is exactly the
   MVVM-with-data-layer shape the Flutter guide recommends. There is no missing
   layer to add.

2. **Constructor injection already gives the testability the layered references
   sell.** `AppState` takes `scanner`, `statusStore`, `fileActions`,
   `preloadController`, `imageLoader`, `dngDecoder`, `exportService`,
   `exifReader` as injected collaborators (`app_state.dart:62-104`), so tests
   substitute fakes without touching the filesystem or platform channels. That
   is the entire practical payoff a Riverpod/GetIt DI migration would promise —
   already present, with zero framework weight.

3. **`ChangeNotifier` is a validated choice here, not a shortcut.** Both Aves
   (a far larger gallery) and the Flutter guide treat built-in
   `ChangeNotifier`/`Listenable` holders as legitimate at this scale. The only
   real `ChangeNotifier` risk — coarse `notifyListeners()` rebuilds of hot
   subtrees — has already been addressed structurally: zoom/animation view state
   was deliberately pulled OUT of `AppState` into `ZoomController`
   (`app_state.dart:144-146`, G-010) precisely to avoid provider-wide rebuilds
   on the perf-sensitive path. The scoping pattern the references would
   recommend is already applied where it pays.

4. **The genuinely hard subsystem is the image pipeline, and it is already
   decomposed further than any reference gallery.** `image_pipeline/` is split
   into ~18 purpose-named units (tier-two scheduler/registry, serial decode
   lane, prefetch scheduler, payload cache, cache budget, source types, sized
   providers). This is finer-grained and more testable than Aves's pipeline, not
   coarser. There is no reference pattern that would simplify it.

## Patterns explicitly considered and rejected as over-engineering

- **Migrate to Riverpod / Bloc / Clean-Architecture-with-domain-layer.** Pure
  cost at 10k LOC: the state library choice is orthogonal to the architecture
  (per the Flutter guide itself), and the testability/DI benefit is already
  achieved via constructor injection. A migration would rewrite every view and
  the single coordination point for no functional or maintainability gain the
  app can currently cash.
- **Introduce a repository/domain interface layer above `services/`.** The
  services already ARE the repository layer; adding interface indirection over a
  single-app, single-implementation codebase is speculative abstraction.
- **Command/Result wrapper for `AppState`'s async actions**
  (`processStarred`, `deleteTrashed`, `exportStarredThumbnails`). The Flutter
  guide's Command pattern would unify their running/error handling, but here
  that duplication spans only ~3 methods and each already reports failures
  honestly via `StatusMessage`. Not enough repetition to pay for the
  abstraction at current size — reconsider only if async-action count grows
  materially.

## Bottom line

Halcyon's structure is already the architecture the strongest references
recommend for an app of this size, and it has independently applied the one
`ChangeNotifier` scoping mitigation that matters. No reference-derived pattern
offers a concrete improvement whose benefit exceeds its cost here.

Sources:
- https://github.com/deckerst/aves
- https://docs.flutter.dev/app-architecture/guide
- https://codewithandrea.com/articles/flutter-app-architecture-riverpod-introduction/
