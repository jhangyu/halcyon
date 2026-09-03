// Plan Task 11 (S4): tier-1 ImageCache registration is paced into the frame.
//
// TC-835b / TC-836b / TC-837b
// (docs/logs/2026-09-03/plan-decode-optimizations.md).
//
// `_precacheTierOneWindow` walked the whole retention window in one
// synchronous loop on every navigation pass, so codec-completion work arrived
// as one clump behind one navigation event. After this task every non-selected
// registration goes through `PublicationPacer`, one per frame, nearest first,
// with the selected item exempt.
//
// The frame hook is a FAKE: no assertion here depends on wall-clock timing or
// on a real `SchedulerBinding` frame.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/publication_pacer.dart';

/// Collects the pacer's armed drains and runs them only when the test says so.
class FakeFrames {
  final List<void Function()> _armed = [];

  void arm(void Function() callback) => _armed.add(callback);

  int get armedCount => _armed.length;

  void frame() {
    final due = List<void Function()>.of(_armed);
    _armed.clear();
    for (final callback in due) {
      callback();
    }
  }
}

/// 26 CHEAP items: the loader answers with real PNG-ish bytes, so no decode
/// lane, no encode stage and no RAW path is involved -- this file is only
/// about WHEN a tier-1 key is registered.
List<PhotoItem> manyCheapItems() => [
  for (var c = 0; c < 26; c++)
    PhotoItem(
      id: String.fromCharCode(0x61 + c),
      files: [File('/tmp/${String.fromCharCode(0x61 + c)}.jpg')],
    ),
];

ImagePreloadController buildController({FrameHook? scheduleFrameCallback}) {
  return ImagePreloadController(
    imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
        // A FRESH bytes object per call, so payload identity is meaningful.
        NativeImageBytes(Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10])),
    scheduleFrameCallback: scheduleFrameCallback,
  );
}

Future<void> pumpMicrotasks([int rounds = 24]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-836b -- the selected item never waits for a frame.
  test('the selected id registers its tier-1 key without a frame', () async {
    final frames = FakeFrames();
    final controller = buildController(scheduleFrameCallback: frames.arm);
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    await controller.preloadImages(
      items: manyCheapItems(),
      selectedItemId: 'c',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();

    expect(
      controller.debugTierOneKeyIds,
      contains('c'),
      reason: 'the exempt (selected) registration must not wait for a frame',
    );
  });

  // TC-835b -- neighbours are paced, one per frame.
  test('non-selected tier-1 registrations are paced one per frame', () async {
    final frames = FakeFrames();
    final controller = buildController(scheduleFrameCallback: frames.arm);
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    await controller.preloadImages(
      items: manyCheapItems(),
      selectedItemId: 'c',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();
    final afterSelection = controller.debugTierOneKeyIds.length;

    frames.frame();
    await pumpMicrotasks();
    expect(controller.debugTierOneKeyIds.length, afterSelection + 1);

    frames.frame();
    await pumpMicrotasks();
    expect(controller.debugTierOneKeyIds.length, afterSelection + 2);
  });

  // TC-837b -- a payload dropped between submit and drain is not registered.
  test('a dropped payload is not registered at drain time', () async {
    final frames = FakeFrames();
    final controller = buildController(scheduleFrameCallback: frames.arm);
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    await controller.preloadImages(
      items: manyCheapItems(),
      selectedItemId: 'c',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();
    // Navigate away so the far neighbours leave the window before their drain.
    await controller.preloadImages(
      items: manyCheapItems(),
      selectedItemId: 'z',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();
    frames.frame();
    await pumpMicrotasks();

    for (final id in controller.debugTierOneKeyIds) {
      expect(
        controller.payloadFor(id),
        isNotNull,
        reason: 'no key may be registered for a dropped payload',
      );
    }
  });

  // The pacer decides WHEN a registration lands, never WHETHER it lands.
  //
  // `PublicationPacer`'s own default queue cap is 4 and its overflow rule
  // DROPS the highest-rank entry outright. One navigation pass submits a
  // registration for every retained slot (-3..+5 == 9 of them), so a cap of 4
  // would silently deny the far half of the window a tier-1 entry forever --
  // the AC2 guarantee. The controller therefore sizes the cap from the
  // retention window. With the cap left at 4 this test fails at 5 keys.
  test('every retained window slot eventually gets a tier-1 key', () async {
    final frames = FakeFrames();
    final controller = buildController(scheduleFrameCallback: frames.arm);
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    await controller.preloadImages(
      items: manyCheapItems(),
      selectedItemId: 'j',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();

    // One drain per frame; pump more frames than the window has slots.
    for (var i = 0; i < 12; i++) {
      frames.frame();
      await pumpMicrotasks(4);
    }

    final windowIds = controller.debugRetentionIds;
    final registered = controller.debugTierOneKeyIds;
    for (final id in windowIds) {
      expect(
        registered,
        contains(id),
        reason: 'slot $id was submitted and must eventually be registered',
      );
    }
    expect(windowIds.length, greaterThan(4), reason: 'the cap is under test');
  });

  // TC-XX10 -- the controller-level twin of TC-XX7: with the pacer's exempt
  // claim enforced against the controller's selected id, a NON-selected window
  // slot cannot register a tier-1 key before a frame is granted, no matter
  // what the caller asks for.
  test('non-selected window items never register a tier-1 key before a frame',
      () async {
    final frames = FakeFrames();
    final controller = buildController(scheduleFrameCallback: frames.arm);
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    await controller.preloadImages(
      items: manyCheapItems(),
      selectedItemId: 'c',
      notifyLoaded: () {},
    );
    await pumpMicrotasks();

    expect(
      controller.debugTierOneKeyIds,
      {'c'},
      reason: 'before any frame, exactly the selected id may be registered',
    );
    expect(controller.debugPacerHasFrameHook, isTrue);
  });
}
