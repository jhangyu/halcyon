import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_state_fixtures.dart';
import '../support/fixture_files.dart';
import '../support/temp_dirs.dart';

const _stubBytes = <int>[1, 2, 3];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // memreclaim spec §4.5: the folder switch is the largest release moment, so
  // it asks the ceyx idle funnel for a pass (replaces the deleted Windows-only
  // working-set trim with the one cross-platform funnel).
  test('loadFolder requests one native reclaim per folder switch', () async {
    final dir = await makeTempDir('halcyon_reclaim_load_');
    await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
    var calls = 0;
    final state = AppState(
      imageLoader: bytesStubLoader,
      requestNativeReclaim: () => calls++,
    );
    addTearDown(state.dispose);

    await state.loadFolder(dir);
    expect(calls, 1);

    await state.loadFolder(dir);
    expect(calls, 2);
  });
}
