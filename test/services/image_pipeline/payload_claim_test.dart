import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_claim.dart';

void main() {
  late PayloadClaimRegistry registry;

  setUp(() {
    registry = PayloadClaimRegistry();
    registry.debugResetCounters();
  });

  test('TC-1030 acquire twice asserts', () {
    registry.acquire('a');
    expect(registry.isHeld('a'), isTrue);
    expect(registry.ownerOf('a'), PayloadClaimOwner.producer);
    expect(() => registry.acquire('a'), throwsA(isA<AssertionError>()));
  });

  test('TC-1031 transfer from wrong owner asserts', () {
    registry.acquire('a');
    expect(
      () => registry.transfer(
        'a',
        from: PayloadClaimOwner.offLaneEncode,
        to: PayloadClaimOwner.laneQueue,
      ),
      throwsA(isA<AssertionError>()),
    );
    registry.transfer(
      'a',
      from: PayloadClaimOwner.producer,
      to: PayloadClaimOwner.offLaneEncode,
    );
    expect(registry.ownerOf('a'), PayloadClaimOwner.offLaneEncode);
  });

  test('TC-1032 release by wrong owner asserts', () {
    registry.acquire('a');
    expect(
      () => registry.release('a', by: PayloadClaimOwner.offLaneEncode),
      throwsA(isA<AssertionError>()),
    );
    expect(registry.release('a', by: PayloadClaimOwner.producer), isTrue);
    expect(registry.isHeld('a'), isFalse);
  });

  test('TC-1033 release after clear is a silent no-op', () {
    registry.acquire('a');
    final generationBefore = registry.generation;
    registry.clear();
    expect(registry.generation, greaterThan(generationBefore));
    expect(registry.release('a', by: PayloadClaimOwner.producer), isFalse);
    expect(registry.length, 0);
  });

  test('TC-1034 handOffToLane drops the claim and arms the awaiting-lane set',
      () {
    registry.acquire('a');
    registry.handOffToLane('a', from: PayloadClaimOwner.producer);
    expect(registry.isHeld('a'), isFalse,
        reason: 'behaviour-preserving: the claim is dropped, as today');
    expect(registry.debugIsAwaitingLane('a'), isTrue);

    // A fresh producer entering during the gap is COUNTED, not asserted.
    registry.acquire('a');
    expect(registry.debugDuplicateProducerCount, 1);

    registry.release('a', by: PayloadClaimOwner.producer);
    expect(registry.assumeFromLane('a'), isTrue);
    expect(registry.assumeFromLane('a'), isFalse);
  });
}
