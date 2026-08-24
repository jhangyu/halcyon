import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/views/theme_tokens.dart';

void main() {
  testWidgets('TC-229 HalcyonTokens.of falls back to dark', (tester) async {
    late HalcyonTokens seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            seen = HalcyonTokens.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, same(HalcyonTokens.dark));
  });

  test('TC-229b lerp returns a HalcyonTokens, not null', () {
    final mid = HalcyonTokens.dark.lerp(HalcyonTokens.light, 0.5);
    expect(mid, isA<HalcyonTokens>());
  });
}
