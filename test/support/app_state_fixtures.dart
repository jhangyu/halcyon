import 'dart:typed_data';

import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

/// Shared fixture for provider tests.
///
/// Extracted from the byte-identical copies duplicated across
/// test/providers/app_state_counts_test.dart, app_state_open_with_test.dart,
/// app_state_working_set_trim_test.dart and app_state_test.dart. Nothing here
/// changes behaviour: it builds an [AppState] with a stub image loader that
/// always returns the same 3-byte payload.
AppState testState() {
  return AppState(
    imageLoader: (path, {required purpose, int? targetLongEdge}) async {
      return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
    },
  );
}
