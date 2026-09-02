import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/layout/darkroom/darkroom_empty_state.dart';
import 'package:provider/provider.dart';

/// TC-588: the darkroom welcome frame (mockup frame 6). Not yet wired into
/// `PhotoViewport`'s empty-state branch (that file is shared and out of this
/// task's ownership — see the round report) but exercised standalone here so
/// its own geometry/content contract is proven ahead of the wiring.
void main() {
  Future<void> pumpWelcome(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: const MaterialApp(home: Scaffold(body: DarkroomEmptyState())),
      ),
    );
  }

  group('TC-588 the welcome frame draws one centred axis', () {
    testWidgets('mount, kicker, headline, sentence, hairline and button all present', (
      tester,
    ) async {
      await pumpWelcome(tester);

      expect(
        find.byKey(const ValueKey('darkroom-welcome-mount')),
        findsOneWidget,
      );
      expect(find.text('DARKROOM'), findsOneWidget);
      expect(find.text('Open a folder to begin'), findsOneWidget);
      expect(
        find.text('Your photos, one at a time, nothing else on screen.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('darkroom-welcome-open')),
        findsOneWidget,
      );
    });

    testWidgets(
      'the Open Folder button is alone on its row (no off-axis sibling)',
      (tester) async {
        await pumpWelcome(tester);

        final buttonFinder = find.byKey(
          const ValueKey('darkroom-welcome-open'),
        );
        final rowFinder = find.ancestor(
          of: buttonFinder,
          matching: find.byType(Row),
        );
        // No ancestor Row shares the button with a shortcut hint or any
        // other sibling — the exact defect NOTES.md records as the gallery
        // off-axis bug this theme must not reproduce.
        expect(rowFinder, findsNothing);
      },
    );

    testWidgets('everything sits on one centred horizontal axis', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await pumpWelcome(tester);

      final mountCenter = tester
          .getRect(find.byKey(const ValueKey('darkroom-welcome-mount')))
          .center
          .dx;
      final buttonCenter = tester
          .getRect(find.byKey(const ValueKey('darkroom-welcome-open')))
          .center
          .dx;
      final headlineCenter = tester
          .getRect(find.text('Open a folder to begin'))
          .center
          .dx;

      expect(buttonCenter, closeTo(mountCenter, 0.5));
      expect(headlineCenter, closeTo(mountCenter, 0.5));
      await tester.binding.setSurfaceSize(null);
    });
  });
}
