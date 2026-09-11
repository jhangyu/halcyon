import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/memory_pressure_responder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/platform/memory_pressure_monitor.dart';

/// TC-1165..TC-1171 (WP4.4 / S3.4 / AC-S3(d) layer 1): the responder's policy,
/// proven against a REAL [PhotoPayloadCache] so the assertions read the actual
/// ledgers (`byteBudget`, `totalByteCost`) rather than a mock's call log.
class _CacheTarget implements MemoryPressureTarget {
  _CacheTarget(this.cache, this.calmPayloadByteBudget);

  final PhotoPayloadCache cache;

  @override
  final int calmPayloadByteBudget;

  int farBandDropCount = 0;

  /// Not an interface member (the responder never reads the in-force budget);
  /// this is the test's own window onto the real ledger.
  int get payloadByteBudget => cache.byteBudget;

  int restoreCount = 0;

  @override
  void setPayloadByteBudget(int bytes) => cache.setByteBudget(bytes);

  /// Mirrors the pipeline primitive `setPayloadByteBudgetOverride(null)`: the
  /// OWNER of the derived number puts it back, which is why this takes no value
  /// from the caller.
  @override
  void restorePayloadByteBudget() {
    restoreCount++;
    cache.setByteBudget(calmPayloadByteBudget);
  }

  @override
  void dropFarBandTierTwoPixels() => farBandDropCount++;
}

void main() {
  const calmBudget = 8 * 1024 * 1024;

  EncodedPayload payload(int bytes) => EncodedPayload(Uint8List(bytes));

  ({
    MemoryPressureMonitor monitor,
    MemoryPressureResponder responder,
    _CacheTarget target,
  }) build() {
    final cache = PhotoPayloadCache(byteBudget: calmBudget);
    // Fill to the calm budget exactly: eight 1 MiB entries.
    for (var i = 0; i < 8; i++) {
      cache.put('photo$i', payload(1024 * 1024));
    }
    final target = _CacheTarget(cache, calmBudget);
    final monitor = MemoryPressureMonitor();
    final responder = MemoryPressureResponder(
      monitor: monitor,
      target: target,
    );
    responder.start();
    return (monitor: monitor, responder: responder, target: target);
  }

  test('TC-1165 calm start changes nothing (generous in calm)', () {
    final built = build();
    expect(built.target.payloadByteBudget, calmBudget);
    expect(built.target.cache.totalByteCost, calmBudget);
    expect(built.target.farBandDropCount, 0);
    expect(built.responder.isUnderPressure, isFalse);
  });

  test('TC-1166 warning halves the budget and the cache actually shrinks', () {
    final built = build();
    final before = (
      budget: built.target.payloadByteBudget,
      cost: built.target.cache.totalByteCost,
    );

    built.responder.applyLevel(MemoryPressureLevel.warning);

    expect(built.target.payloadByteBudget, calmBudget ~/ 2);
    expect(built.target.payloadByteBudget, lessThan(before.budget));
    // The ledger, not the setter: setByteBudget sweeps immediately, so the
    // retained bytes must have fallen to within the halved budget.
    expect(built.target.cache.totalByteCost, lessThan(before.cost));
    expect(
      built.target.cache.totalByteCost,
      lessThanOrEqualTo(built.target.payloadByteBudget),
    );
    expect(built.target.farBandDropCount, 1);
    expect(built.responder.isUnderPressure, isTrue);
  });

  test('TC-1167 normal restores the derived budget (no permanent degradation)',
      () {
    final built = build();
    built.responder.applyLevel(MemoryPressureLevel.warning);
    expect(built.target.payloadByteBudget, calmBudget ~/ 2);

    built.responder.applyLevel(MemoryPressureLevel.normal);

    expect(built.target.payloadByteBudget, calmBudget);
    expect(built.target.restoreCount, 1);
    expect(built.responder.isUnderPressure, isFalse);
  });

  test('TC-1168 repeated pressure does not halve a halved budget', () {
    final built = build();
    built.responder.applyLevel(MemoryPressureLevel.warning);
    built.responder.applyLevel(MemoryPressureLevel.warning);
    built.responder.applyLevel(MemoryPressureLevel.critical);

    expect(built.target.payloadByteBudget, calmBudget ~/ 2);
    // The cheap half of the response repeats on every signal.
    expect(built.target.farBandDropCount, 3);
  });

  test('TC-1169 correct on a platform that only ever reports normal/warning',
      () {
    final built = build();
    // Exactly the Windows two-state sequence: signalled -> complement -> ...
    for (var cycle = 0; cycle < 3; cycle++) {
      built.responder.applyLevel(MemoryPressureLevel.warning);
      expect(built.target.payloadByteBudget, calmBudget ~/ 2);
      built.responder.applyLevel(MemoryPressureLevel.normal);
      expect(built.target.payloadByteBudget, calmBudget);
    }
    expect(built.target.farBandDropCount, 3);
    expect(built.responder.isUnderPressure, isFalse);
  });

  test('TC-1170 normal while already calm is a no-op', () {
    final built = build();
    built.responder.applyLevel(MemoryPressureLevel.normal);
    expect(built.target.payloadByteBudget, calmBudget);
    expect(built.target.cache.totalByteCost, calmBudget);
    expect(built.target.farBandDropCount, 0);
    // Not merely "budget unchanged": the restore primitive must not even be
    // CALLED while calm, or a pressure-free session would be writing budgets.
    expect(built.target.restoreCount, 0);
  });

  test('TC-1171 a push over the monitor drives the responder end to end',
      () async {
    final built = build();
    await built.monitor.handleMethodCall(
      const MethodCall(MemoryPressureMonitor.methodName, 'warning'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(built.target.payloadByteBudget, calmBudget ~/ 2);
    expect(
      built.target.cache.totalByteCost,
      lessThanOrEqualTo(calmBudget ~/ 2),
    );
    expect(built.target.farBandDropCount, 1);
    await built.monitor.dispose();
  });
}
