// Compressed residency v2 Task 4: the PRODUCTION composition root must turn the
// deferred full-size residency path ON.
//
// The deferred encode is opt-in at `ImagePreloadController`
// (`deferredEncodeDecoder`, null => the job abandons before decoding), which is
// what lets the pre-existing decode-arithmetic tests keep their exact counts.
// The price of that shape is a silent-absence failure mode: a binding that
// forgets the argument loses compressed residency entirely, nothing throws, and
// every other test in the suite stays green -- the same class as the shipped
// FFI lookup that null'd itself out (lessons-learned 2026-09-06). This file is
// the mechanical guard against exactly that, and plan Task 9's AC-1 live
// capture is its end-to-end backstop.
//
// TC-1230 / TC-1231.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<DecodedRgba> _decoder(String path) async => DecodedRgba(
  rgba: Uint8List.fromList(
    List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : i),
  ),
  width: 2,
  height: 2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // TC-1230
  test(
    'the production AppState wires the deferred residency decoder, and wires '
    'the SAME decoder it gives the main pipeline',
    () {
      final state = AppState(dngDecoder: _decoder);
      addTearDown(state.dispose);

      // Read through the controller AppState actually built, resolved through
      // the very supplier the deferred job holds -- not through a copy of the
      // argument list, which would agree with a wiring that was never passed.
      expect(
        state.debugDeferredEncodeDecoder,
        isNotNull,
        reason:
            'without this argument every retained PixelPayload stays a pixel '
            'payload forever: compressed residency would be silently absent in '
            'the shipped app while the whole test suite stayed green',
      );
      expect(
        identical(state.debugDeferredEncodeDecoder, _decoder),
        isTrue,
        reason:
            'the deferred job must re-decode with the same decoder the '
            'pipeline uses, not a second one that could drift from it',
      );
    },
  );

  // TC-1231 -- the negative half: with no RAW decoder to give, the supplier
  // resolves to null and the deferred job takes its specced abandon exit. This
  // is what stops TC-1230 from being satisfiable by a hard-coded non-null.
  test('an AppState with no RAW decoder supplies no deferred decoder', () {
    final state = AppState();
    addTearDown(state.dispose);

    expect(state.debugDeferredEncodeDecoder, isNull);
  });

  // An injected controller keeps whatever wiring its injector chose, exactly
  // as TC-905 asserts for the pacing seams.
  test('an injected controller is not re-wired with a deferred decoder', () {
    final injected = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])),
    );
    final state = AppState(dngDecoder: _decoder, preloadController: injected);
    addTearDown(state.dispose);

    expect(injected.debugDeferredEncodeDecoder, isNull);
  });
}
