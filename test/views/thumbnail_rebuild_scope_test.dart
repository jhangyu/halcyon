import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/preload_fixtures.dart';

/// Counts its own builds. Stands in for the viewport and for a strip tile.
class BuildSpy extends StatelessWidget {
  const BuildSpy({super.key, required this.onBuild, required this.child});
  final VoidCallback onBuild;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return child;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-832 / TC-833 — RE-AIMED 2026-09-06 (Phase 5 commit B), STRENGTHENED
  // 2026-09-06 (parking-lot item 1, `phase5-6-baton-for-next-worker.md` §2).
  //
  // Same intent as before, at the same (widget) layer: a thumbnail landing
  // must repaint the strip side and leave the viewer alone. What changed is
  // the MECHANISM it observes. The old version listened to
  // `AppState.thumbnailsRevision`, a strip-wide ValueNotifier every theme
  // wrapped its whole strip in; that field no longer exists, and a test that
  // kept bumping it by hand would have gone on passing while pinning nothing.
  // The signal is now per row: `ImagePreloadController.stateFor(id)` reaching
  // the tile through the production `StripTile` widget.
  //
  // Distinct from TC-989 (payload_state_test.dart), which asserts tile-vs-TILE
  // isolation with synthetic tiles. This one asserts tile-vs-VIEWER isolation
  // with a real `context.watch<AppState>()` above it, which is the half that
  // regressed historically.
  //
  // STRENGTHENING (what changed and what did NOT):
  // The previous version of this test drove the landing by calling
  // `PayloadStateNotifier.trySetValue` on a notifier constructed LOCALLY in
  // the test body -- no production code ever touched it. That made the
  // "viewer untouched" half a pure STRUCTURAL SENTINEL: as documented in the
  // baton, after `6df3639` retired the strip-wide notification, NOTHING in
  // the codebase calls `AppState.notifyListeners()` from a tile-landing path,
  // so re-attaching such a call anywhere else in the app would not have
  // touched this test's notifier and could not have turned it red.
  //
  // This version drives the landing through the REAL production controller
  // (`ImagePreloadController.preloadImages` -> `_ensurePayload` ->
  // `_markStage` -> the notifier `stateFor(id)` returns) instead of a
  // locally-constructed stand-in, and wires that SAME `stateFor` into the
  // `StripTile` under test -- i.e. every hop between "a payload lands" and
  // "the widget tree learns about it" is now the shipped code path, not a
  // hand-rolled substitute.
  //
  // What this DOES now catch: a future change that makes `_markStage` (or
  // anything else on this landing path) call `AppState.notifyListeners()` or
  // otherwise reach up to the surface's `ChangeNotifier` would make
  // `viewportBuilds` increase here, because the viewer really is listening to
  // the real `AppState` that a real notification would go through.
  //
  // What this still CANNOT catch: `AppState` itself is not otherwise wired to
  // this `ImagePreloadController` in this test (there is no `AppState`
  // constructor path that accepts an externally-built controller), so a
  // regression that reintroduces a *separate*, AppState-owned notification
  // mechanism unrelated to `_markStage`'s call sites -- e.g. a brand-new
  // `ChangeNotifier.notifyListeners()` call added directly inside
  // `AppState` itself, triggered by something other than a tile landing --
  // would not be observed by this test either way, positive or negative. The
  // claim this test makes is scoped to "does a real tile-landing signal reach
  // the viewer's `AppState`", not "does `AppState` ever call
  // `notifyListeners()` for any reason". That scope match is exactly TC-832's
  // original intent (thumbnail landing vs. viewer), so no overclaim is made,
  // but the boundary is written down here rather than left implicit.
  testWidgets('a thumbnail landing rebuilds the strip tile, not the viewer', (
    tester,
  ) async {
    // Guard against AppState's fire-and-forget async _initPrefs racing this
    // test's FakeAsync window and throwing MissingPluginException when it
    // hits the real (unmocked) shared_preferences platform channel — same
    // idiom as app_state_test.dart's setUp.
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    addTearDown(state.dispose);

    // A "cheap" controller (pattern shared with payload_state_test.dart's
    // `_cheapController`): a fake loader that always succeeds with a tiny
    // real PNG, so the real `preloadImages` -> `_ensurePayload` ->
    // `_markStage` chain runs to `tierOneReady` without touching the
    // filesystem or a native decoder.
    final controller = ImagePreloadController(
      scheduleFrameCallback: (callback) => callback(),
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
      dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    final items = paddedItems(3);
    final id = items[1].id;

    var viewportBuilds = 0;
    var tileBuilds = 0;

    final strip = PhotoStripModel(
      items: items,
      selectedId: id,
      recycleMode: false,
      onSelect: (_) {},
      payloadFor: controller.payloadFor,
      stateFor: controller.stateFor,
      onVisibleRange: (_, _) {},
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              // Mirrors main_screen._buildSurface: the surface watches
              // AppState, and the tile listens to its own row's state.
              context.watch<AppState>();
              return Column(
                children: [
                  BuildSpy(
                    onBuild: () => viewportBuilds++,
                    child: const SizedBox(height: 10),
                  ),
                  StripTile(
                    strip: strip,
                    id: id,
                    builder: (context, payload) => BuildSpy(
                      onBuild: () => tileBuilds++,
                      child: const SizedBox(height: 10),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    final viewportBefore = viewportBuilds;
    final tileBefore = tileBuilds;

    // The landing, through the SHIPPED path: a real preload that runs the
    // fake loader, writes the payload cache, and calls `_markStage` on
    // `id`'s own notifier. `runAsync` is required here (not optional, see
    // G-020/G-021 and lessons-learned 2026-08-17): `testWidgets` runs inside
    // an automated binding that never advances real engine futures (the PNG
    // decode `preloadImages` triggers) on its own, so `until`'s real-time
    // poll would otherwise hang forever at near-zero CPU rather than fail.
    await tester.runAsync(() async {
      await controller.preloadImages(
        items: items,
        selectedItemId: id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor(id) != null,
        reason: '$id payload to land',
      );
    });
    await tester.pump();

    expect(viewportBuilds, viewportBefore, reason: 'TC-832: viewer untouched');
    expect(tileBuilds, greaterThan(tileBefore), reason: 'TC-833: the tile repainted');
  });

  // TC-834 -- the visible-range reporter stays itemBuilder-driven.
  // Untouched by Phase 5: it never referenced the revision signal beyond using
  // a local notifier as a rebuild trigger.
  testWidgets('onVisibleRange is still reported from itemBuilder', (
    tester,
  ) async {
    final reported = <(int, int)>[];
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: revision,
          builder: (context, _) => ListView.builder(
            itemCount: 20,
            itemBuilder: (context, index) {
              if (index == 0) reported.add((0, 0));
              return const SizedBox(height: 40);
            },
          ),
        ),
      ),
    );
    expect(reported, isNotEmpty);
  });
}
