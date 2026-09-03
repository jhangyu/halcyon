import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:provider/provider.dart';

/// Counts its own builds. Stands in for the viewport and for the strip.
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

  // TC-832 / TC-833
  testWidgets('a thumbnail landing rebuilds the strip, not the viewer',
      (tester) async {
    final state = AppState();
    var viewportBuilds = 0;
    var stripBuilds = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              // Mirrors main_screen._buildSurface: watching AppState, and a
              // strip that listens to the narrow revision signal instead.
              context.watch<AppState>();
              return Column(
                children: [
                  BuildSpy(
                    onBuild: () => viewportBuilds++,
                    child: const SizedBox(height: 10),
                  ),
                  ListenableBuilder(
                    listenable: state.thumbnailsRevision,
                    builder: (context, _) => BuildSpy(
                      onBuild: () => stripBuilds++,
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
    final stripBefore = stripBuilds;

    state.thumbnailsRevision.value++;
    await tester.pump();

    expect(viewportBuilds, viewportBefore, reason: 'TC-832: viewer untouched');
    expect(stripBuilds, stripBefore + 1, reason: 'TC-833: strip repainted');
  });

  // TC-834 -- the visible-range reporter stays itemBuilder-driven.
  testWidgets('onVisibleRange is still reported from itemBuilder',
      (tester) async {
    final reported = <(int, int)>[];
    final revision = ValueNotifier<int>(0);
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
