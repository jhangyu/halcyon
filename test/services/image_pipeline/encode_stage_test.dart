import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/encode_stage.dart';

void main() {
  test('runningCount never exceeds width', () async {
    final stage = EncodeStage(width: 2);
    final gates = List.generate(10, (_) => Completer<void>());
    var peak = 0;
    for (final gate in gates) {
      unawaited(stage.run(() async {
        peak = peak > stage.runningCount ? peak : stage.runningCount;
        await gate.future;
      }));
    }
    await Future<void>.delayed(Duration.zero);
    expect(stage.runningCount, 2);
    for (final gate in gates) {
      gate.complete();
      await Future<void>.delayed(Duration.zero);
    }
    expect(peak, lessThanOrEqualTo(2));
    expect(stage.runningCount, 0);
  });

  test('start order is FIFO', () async {
    final stage = EncodeStage(width: 1);
    final started = <int>[];
    final gate = Completer<void>();
    unawaited(stage.run(() async {
      started.add(1);
      await gate.future;
    }));
    unawaited(stage.run(() async => started.add(2)));
    unawaited(stage.run(() async => started.add(3)));
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(started, [1, 2, 3]);
  });

  test('a throwing body reaches its own caller and does not wedge the stage',
      () async {
    final stage = EncodeStage(width: 1);
    await expectLater(
      stage.run(() async => throw StateError('encode failed')),
      throwsStateError,
    );
    expect(await stage.run(() async => 42), 42);
  });

  test('widening admits more bodies on the next microtask', () async {
    final stage = EncodeStage(width: 1);
    final gates = List.generate(3, (_) => Completer<void>());
    for (final gate in gates) {
      unawaited(stage.run(() => gate.future));
    }
    await Future<void>.delayed(Duration.zero);
    expect(stage.runningCount, 1);
    stage.width = 3;
    await Future<void>.delayed(Duration.zero);
    expect(stage.runningCount, 3);
    for (final gate in gates) {
      gate.complete();
    }
  });

  test('clear fails pending bodies and leaves running ones alone', () async {
    final stage = EncodeStage(width: 1);
    final gate = Completer<void>();
    unawaited(stage.run(() => gate.future));
    await Future<void>.delayed(Duration.zero);
    final pending = stage.run(() async => 1);
    stage.clear();
    await expectLater(pending, throwsStateError);
    expect(stage.runningCount, 1);
    gate.complete();
  });
}
