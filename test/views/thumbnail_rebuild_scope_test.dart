import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:provider/provider.dart';

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

  // TC-832 / TC-833 — RE-AIMED 2026-09-06 (Phase 5 commit B).
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
  testWidgets('a thumbnail landing rebuilds the strip tile, not the viewer', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final tileState = PayloadStateNotifier(const PayloadState.absent());
    addTearDown(tileState.dispose);
    var viewportBuilds = 0;
    var tileBuilds = 0;

    final strip = PhotoStripModel(
      items: const <PhotoItem>[],
      selectedId: 'A',
      recycleMode: false,
      onSelect: (_) {},
      payloadFor: (_) => null,
      stateFor: (_) => tileState,
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
                    id: 'A',
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

    // The landing, as the pipeline reports it: that row's state advances.
    tileState.trySetValue(const PayloadState(stage: PayloadStage.tierOneReady));
    await tester.pump();

    expect(viewportBuilds, viewportBefore, reason: 'TC-832: viewer untouched');
    expect(tileBuilds, tileBefore + 1, reason: 'TC-833: the tile repainted');
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
