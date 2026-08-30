import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';

/// A body that reports when it starts, and finishes when its completer does.
({Future<void> Function() body, Completer<void> gate, List<String> starts})
    tracked(String name, List<String> starts) {
  final gate = Completer<void>();
  return (
    body: () async {
      starts.add(name);
      await gate.future;
    },
    gate: gate,
    starts: starts,
  );
}

void main() {
  test('TC-340 width 1 runs one body at a time', () async {
    final lane = DecodeLane(width: 1);
    var inFlight = 0;
    var maxInFlight = 0;
    for (var i = 0; i < 5; i++) {
      lane.enqueue(
        (LaneTaskKind.payload, 'p$i'),
        priority: i,
        body: () async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
        },
      );
    }
    while (lane.pendingCount > 0 || lane.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(maxInFlight, 1);
  });

  test('TC-341 width 3 runs up to three bodies at a time', () async {
    final lane = DecodeLane(width: 3);
    var inFlight = 0;
    var maxInFlight = 0;
    for (var i = 0; i < 9; i++) {
      lane.enqueue(
        (LaneTaskKind.payload, 'p$i'),
        priority: i,
        body: () async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
        },
      );
    }
    while (lane.pendingCount > 0 || lane.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(maxInFlight, 3);
  });

  test('TC-342 start order is global priority order, whatever the width',
      () async {
    final lane = DecodeLane(width: 3);
    final starts = <String>[];
    // Enqueued worst-first, in one synchronous burst.
    for (final entry in [('far', 9), ('mid', 5), ('near', 0)]) {
      lane.enqueue(
        (LaneTaskKind.payload, entry.$1),
        priority: entry.$2,
        body: () async {
          starts.add(entry.$1);
          await Future<void>.delayed(const Duration(milliseconds: 5));
        },
      );
    }
    while (lane.pendingCount > 0 || lane.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(starts, ['near', 'mid', 'far']);
  });

  test('TC-343 no body starts synchronously inside enqueue', () async {
    final lane = DecodeLane(width: 3);
    var started = false;
    lane.enqueue(
      (LaneTaskKind.payload, 'a'),
      priority: 0,
      body: () async => started = true,
    );
    expect(started, isFalse, reason: 'the pump is a microtask, not inline');
    await Future<void>.delayed(Duration.zero);
    expect(started, isTrue);
  });

  test('TC-344 a re-enqueued pending key is reprioritised, not duplicated',
      () async {
    final lane = DecodeLane(width: 1);
    final starts = <String>[];
    final block = Completer<void>();
    lane.enqueue(
      (LaneTaskKind.payload, 'blocker'),
      priority: 0,
      body: () async {
        starts.add('blocker');
        await block.future;
      },
    );
    await Future<void>.delayed(Duration.zero);
    lane.enqueue(
      (LaneTaskKind.payload, 'x'),
      priority: 9,
      body: () async => starts.add('x'),
    );
    lane.enqueue(
      (LaneTaskKind.payload, 'y'),
      priority: 5,
      body: () async => starts.add('y'),
    );
    lane.enqueue(
      (LaneTaskKind.payload, 'x'),
      priority: 1,
      body: () async => starts.add('x'),
    );
    expect(lane.pendingCount, 2, reason: 'x replaced its own entry');
    block.complete();
    while (lane.pendingCount > 0 || lane.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(starts, ['blocker', 'x', 'y']);
  });

  test('TC-345 a throwing body does not wedge any runner', () async {
    final lane = DecodeLane(width: 2);
    final done = <String>[];
    lane.enqueue(
      (LaneTaskKind.payload, 'bad'),
      priority: 0,
      body: () async => throw StateError('boom'),
    );
    lane.enqueue(
      (LaneTaskKind.payload, 'good'),
      priority: 1,
      body: () async => done.add('good'),
    );
    while (lane.pendingCount > 0 || lane.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(done, ['good']);
  });

  test('TC-346 widening at runtime starts pending work; narrowing never '
      'pre-empts an in-flight body', () async {
    final lane = DecodeLane(width: 1);
    var inFlight = 0;
    var maxInFlight = 0;
    final gate = Completer<void>();
    for (var i = 0; i < 4; i++) {
      lane.enqueue(
        (LaneTaskKind.payload, 'p$i'),
        priority: i,
        body: () async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await gate.future;
          inFlight--;
        },
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(inFlight, 1);
    lane.width = 3;
    await Future<void>.delayed(Duration.zero);
    expect(inFlight, 3, reason: 'widening fills the new slots');
    lane.width = 1;
    expect(inFlight, 3, reason: 'narrowing cannot cancel an FFI decode');
    gate.complete();
    while (lane.pendingCount > 0 || lane.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(maxInFlight, 3);
  });
}
