import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/file_retry.dart';
import 'package:halcyon_flutter/services/platform/working_set_trim.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_state_fixtures.dart';
import '../support/fixture_files.dart';

const _stubBytes = <int>[1, 2, 3];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkingSetTrim.debugReset();
  });
  tearDown(WorkingSetTrim.debugReset);

  // TC-492
  test('loadFolder trims immediately, exactly once', () async {
    final dir = await Directory.systemTemp.createTemp('halcyon_wst_load_');
    // On Windows, Defender/the search indexer can hold a just-written file
    // open for a few tens of milliseconds after this test's own I/O
    // completes (AD-038, see file_retry.dart) -- a bare `dir.delete` catches
    // that window and fails the whole test with an unrelated
    // PathAccessException. Retry with the same production-approved schedule
    // used for real user-data renames; POSIX hosts hit success on the first
    // attempt and pay nothing.
    addTearDown(
      () => retryOnSharingViolation(() => dir.delete(recursive: true)),
    );
    await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
    await writeFixtureBytes(dir, 'IMG_0002.jpg', _stubBytes);

    final state = testState();
    addTearDown(state.dispose);
    await state.loadFolder(dir);

    expect(WorkingSetTrim.debugTrimNowCalls, 1);
  });
}
