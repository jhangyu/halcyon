import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/working_set_trim.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_state_fixtures.dart';
import '../support/fixture_files.dart';
import '../support/temp_dirs.dart';

const _stubBytes = <int>[1, 2, 3];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkingSetTrim.debugReset();
  });
  tearDown(WorkingSetTrim.debugReset);

  // TC-492
  test('loadFolder trims immediately, exactly once', () async {
    final dir = await makeTempDir('halcyon_wst_load_');
    await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
    await writeFixtureBytes(dir, 'IMG_0002.jpg', _stubBytes);

    final state = testState();
    addTearDown(state.dispose);
    await state.loadFolder(dir);

    expect(WorkingSetTrim.debugTrimNowCalls, 1);
  });
}
