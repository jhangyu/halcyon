import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/inflight_bytes_budget.dart';

void main() {
  // TC-839
  test('acquire blocks past maxBytes and admits on release', () async {
    final budget = InflightBytesBudget(maxBytes: 100);
    await budget.acquire(60);
    await budget.acquire(30);
    expect(budget.inFlightBytes, 90);

    var third = false;
    unawaited(budget.acquire(30).then((_) => third = true));
    await Future<void>.delayed(Duration.zero);
    expect(third, isFalse, reason: '90 + 30 exceeds 100');
    expect(budget.waitingCount, 1);

    budget.release(60);
    await Future<void>.delayed(Duration.zero);
    expect(third, isTrue);
    expect(budget.inFlightBytes, 60);
  });

  // TC-840
  test('an oversized request is admitted when the budget is empty', () async {
    final budget = InflightBytesBudget(maxBytes: 100);
    await budget.acquire(500).timeout(const Duration(seconds: 1));
    expect(budget.inFlightBytes, 500);
  });

  // TC-840b
  test('an oversized request still waits for an occupied budget', () async {
    final budget = InflightBytesBudget(maxBytes: 100);
    await budget.acquire(60);
    var admitted = false;
    unawaited(budget.acquire(500).then((_) => admitted = true));
    await Future<void>.delayed(Duration.zero);
    expect(admitted, isFalse);
    budget.release(60);
    await Future<void>.delayed(Duration.zero);
    expect(admitted, isTrue);
  });

  test('FIFO: a large head blocks the small waiter behind it', () async {
    final budget = InflightBytesBudget(maxBytes: 100);
    await budget.acquire(100);
    var big = false;
    var small = false;
    unawaited(budget.acquire(80).then((_) => big = true));
    unawaited(budget.acquire(10).then((_) => small = true));
    budget.release(20);
    await Future<void>.delayed(Duration.zero);
    expect(big, isFalse);
    expect(small, isFalse, reason: 'the head of the queue blocks the tail');
    budget.release(80);
    await Future<void>.delayed(Duration.zero);
    expect(big, isTrue);
    expect(small, isTrue);
  });

  test('clear completes every waiter and zeroes the counter', () async {
    final budget = InflightBytesBudget(maxBytes: 10);
    await budget.acquire(10);
    var a = false;
    var b = false;
    unawaited(budget.acquire(5).then((_) => a = true));
    unawaited(budget.acquire(5).then((_) => b = true));
    budget.clear();
    await Future<void>.delayed(Duration.zero);
    expect(a, isTrue);
    expect(b, isTrue);
    expect(budget.inFlightBytes, 0);
    expect(budget.waitingCount, 0);
  });
}
