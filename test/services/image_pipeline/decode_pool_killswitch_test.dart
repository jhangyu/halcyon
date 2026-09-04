import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';

/// TC-944: the `--dart-define=HALCYON_DECODE_POOL=0` kill switch.
///
/// The switch exists so the SAME build tree can be captured with the pool on
/// and off, which is the only A/B that controls for every other change landed
/// in a round. A switch that silently does nothing would make that comparison
/// produce two identical captures and "prove" the pool innocent — so the
/// parsing is what gets tested, not the plumbing.
void main() {
  test('TC-944: the define parses the documented spellings', () {
    // Not supplied -> pool ON. This is the shipped default.
    expect(decodePoolEnabledFor(''), isTrue);
    expect(kDecodePoolEnabled, isTrue,
        reason: 'the test suite runs without the define, so the default arm '
            'must be the pool');

    // The documented off spellings must all actually turn it OFF. `0` is the
    // trap: `bool.fromEnvironment` would return its DEFAULT for this value,
    // leaving the pool on while the operator believes it is off.
    expect(decodePoolEnabledFor('0'), isFalse);
    expect(decodePoolEnabledFor('false'), isFalse);
    expect(decodePoolEnabledFor('off'), isFalse);

    // Anything else means on: an unrecognised value must not silently disable
    // the production path.
    expect(decodePoolEnabledFor('1'), isTrue);
    expect(decodePoolEnabledFor('true'), isTrue);
    expect(decodePoolEnabledFor('yes'), isTrue);

    // The const and the callable spell the same rule twice (Dart forbids a
    // method call in a const expression). Pin them together so they cannot
    // drift: a build could otherwise honour a spelling the tests reject, or
    // vice versa.
    expect(decodePoolEnabledFor(kDecodePoolDefine), equals(kDecodePoolEnabled));
  });
}
