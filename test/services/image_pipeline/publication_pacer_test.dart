import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/publication_pacer.dart';

/// A fake frame clock: `arm` records the drain callback, `frame()` runs it.
class FakeFrames {
  final List<VoidCallback> _armed = [];
  void arm(VoidCallback callback) => _armed.add(callback);
  int get armedCount => _armed.length;
  void frame() {
    final due = List<VoidCallback>.of(_armed);
    _armed.clear();
    for (final callback in due) {
      callback();
    }
  }
}

void main() {
  // TC-835
  test('at most one publication per frame', () {
    final frames = FakeFrames();
    final published = <String>[];
    final pacer =
        PublicationPacer(scheduleFrameCallback: frames.arm, perFrame: 1);
    for (final id in ['a', 'b', 'c']) {
      pacer.submit(
        id: id,
        rank: 1,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(id),
      );
    }
    frames.frame();
    expect(published.length, 1);
    frames.frame();
    expect(published.length, 2);
    frames.frame();
    expect(published.length, 3);
  });

  // TC-836
  test('an exempt entry publishes inside submit', () {
    final frames = FakeFrames();
    final published = <String>[];
    final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
    pacer.submit(
      id: 'sel',
      rank: 0,
      exempt: true,
      stillValid: () => true,
      publish: () => published.add('sel'),
    );
    expect(published, ['sel']);
    expect(frames.armedCount, 0);
    expect(pacer.queuedCount, 0);
  });

  // TC-837
  test('an entry invalidated between submit and drain is discarded', () {
    final frames = FakeFrames();
    var valid = true;
    var published = 0;
    var discarded = 0;
    final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
    pacer.submit(
      id: 'a',
      rank: 1,
      exempt: false,
      stillValid: () => valid,
      publish: () => published++,
      discard: () => discarded++,
    );
    valid = false;
    frames.frame();
    expect(published, 0);
    expect(discarded, 1);
    expect(pacer.queuedCount, 0);
  });

  // TC-838
  test('overflow drops the farthest-ranked entry', () {
    final frames = FakeFrames();
    final dropped = <String>[];
    final pacer = PublicationPacer(
      scheduleFrameCallback: frames.arm,
      maxQueued: 2,
    );
    for (final entry in [('near', 1), ('far', 5), ('mid', 3)]) {
      pacer.submit(
        id: entry.$1,
        rank: entry.$2,
        exempt: false,
        stillValid: () => true,
        publish: () {},
        discard: () => dropped.add(entry.$1),
      );
    }
    expect(dropped, ['far']);
    expect(pacer.queuedCount, 2);
  });

  test('drain order is ascending rank, not submit order', () {
    final frames = FakeFrames();
    final published = <String>[];
    final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
    for (final entry in [('far', 9), ('near', 1), ('mid', 4)]) {
      pacer.submit(
        id: entry.$1,
        rank: entry.$2,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(entry.$1),
      );
    }
    frames.frame();
    frames.frame();
    frames.frame();
    expect(published, ['near', 'mid', 'far']);
  });

  test('re-submitting a queued id replaces it and discards the old entry', () {
    final frames = FakeFrames();
    final dropped = <String>[];
    final published = <int>[];
    final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
    pacer.submit(
      id: 'a',
      rank: 5,
      exempt: false,
      stillValid: () => true,
      publish: () => published.add(1),
      discard: () => dropped.add('first'),
    );
    pacer.submit(
      id: 'a',
      rank: 1,
      exempt: false,
      stillValid: () => true,
      publish: () => published.add(2),
      discard: () => dropped.add('second'),
    );
    expect(dropped, ['first']);
    expect(pacer.queuedCount, 1);
    frames.frame();
    expect(published, [2]);
  });

  test('clear discards every queued entry', () {
    final frames = FakeFrames();
    var discarded = 0;
    final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
    for (final id in ['a', 'b']) {
      pacer.submit(
        id: id,
        rank: 1,
        exempt: false,
        stillValid: () => true,
        publish: () {},
        discard: () => discarded++,
      );
    }
    pacer.clear();
    expect(discarded, 2);
    expect(pacer.queuedCount, 0);
  });
}
