// R3-WP8 (docs/logs/2026-09-06/gc-remediation-plan.md Task 9).
//
// Per-frame publish BYTE quota (`PublicationPacer.perFrameBytes` /
// `submit`'s `byteCost`), alongside the pre-existing per-frame COUNT budget,
// and the batched-drain assertion (AC9.5): several entries queued in the same
// turn drain in ONE `_drain` call.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/frame_bytes.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/publication_pacer.dart';

void main() {
  // TC-1056
  test('a frame publishes at most perFrameBytes', () {
    final published = <String>[];
    late VoidCallback drain;
    final pacer = PublicationPacer(
      scheduleFrameCallback: (cb) => drain = cb,
      perFrame: 10, // count is deliberately NOT the constraint
      perFrameBytes: 100 * 1024 * 1024,
      isSelected: (_) => false,
    );
    for (final id in ['a', 'b', 'c']) {
      pacer.submit(
        id: id,
        rank: 0,
        byteCost: 50 * 1024 * 1024,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(id),
      );
    }
    drain();
    expect(published.length, 2, reason: '2 x 50MB fits, the third does not');
    expect(
      pacer.debugBytesPublishedLastFrame,
      lessThanOrEqualTo(100 * 1024 * 1024),
    );
    drain();
    expect(published.length, 3);
  });

  // Positive control: a single entry bigger than the WHOLE per-frame byte
  // quota still publishes when it is first this frame -- otherwise a ~97MB
  // upload would never publish at all (plan Step 9.3's stated rule, mirrored
  // from InflightBytesBudget's empty-budget clause).
  test('an oversized entry publishes anyway when it is first this frame', () {
    final published = <String>[];
    late VoidCallback drain;
    final pacer = PublicationPacer(
      scheduleFrameCallback: (cb) => drain = cb,
      perFrame: 10,
      perFrameBytes: 10,
      isSelected: (_) => false,
    );
    pacer.submit(
      id: 'huge',
      rank: 0,
      byteCost: 1000,
      exempt: false,
      stillValid: () => true,
      publish: () => published.add('huge'),
    );
    drain();
    expect(published, ['huge']);
    expect(pacer.debugBytesPublishedLastFrame, 1000);
  });

  // AC9.5 -- batched drain: four entries submitted in the SAME turn (before
  // the frame hook fires) must drain in ONE `_drain` call, not four.
  test('four simultaneous completions drain in a single batch', () {
    final published = <String>[];
    late VoidCallback drain;
    final pacer = PublicationPacer(
      scheduleFrameCallback: (cb) => drain = cb,
      perFrame: 10,
      perFrameBytes: 100 * 1024 * 1024,
      isSelected: (_) => false,
    );
    for (final id in ['a', 'b', 'c', 'd']) {
      pacer.submit(
        id: id,
        rank: 0,
        byteCost: 1024,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(id),
      );
    }
    drain();
    expect(published.length, 4);
    expect(pacer.debugBatchesDrained, 1);
    expect(pacer.debugMaxBatchSize, 4);
  });

  // TC-1290..TC-1292 -- mem8 T9 (SR-5): the byte quota WIRED IN PRODUCTION.
  //
  // HONESTY LABEL, binding (user ruling 2026-09-12, option A): `perFrameBytes`
  // bounds bytes published PER FRAME. It does NOT cap parked bytes -- parked
  // depth is still bounded by `maxQueued` as a COUNT, so the pathological
  // parked total is unchanged. SR-5's "864 MB -> ~192 MB saving" claim is
  // RETIRED; nothing below asserts a saving. The parked-bytes gauge REPORTS.
  //
  // WHY THE WIRING NEEDS ITS OWN TEST: every pacer test above builds its own
  // pacer with its own budget, so all of them stay green if the production
  // construction never passes `perFrameBytes` at all. The wiring is the whole
  // deliverable of T9 and is otherwise invisible.
  group('mem8 T9 (SR-5): the per-frame byte quota in production', () {
    test('TC-1290: the production pacer is built with a finite byte budget',
        () {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose, targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
      );
      addTearDown(controller.dispose);
      expect(
        controller.debugPacerPerFrameBytes,
        // FAMILY B (display), not family A. The pacer's CHARGES are
        // `image.width * image.height * 4` ui.Image uploads, so its quota must
        // be in display units — a quota and its charges must share units.
        // These two constants were numerically equal until mem8 T15b moved the
        // decode-output one to yuv420; this line read family A and only became
        // observably wrong at that moment. TC-1341 pins the production side of
        // the same rule.
        2 * kNominalFullFrameDisplayBytes,
        reason: 'SR-5: ~2 full-res frames per frame. Reading 1 << 62 (the '
            "parameter's unbounded default) means Step 9.1 was reverted and "
            'the byte half of the quota is inert in production -- which no '
            'other test in this file can see, because they all build their '
            'own pacers.',
      );
    });

    test('TC-1291: the selected item still publishes synchronously with the '
        "frame's byte budget already spent", () {
      final published = <String>[];
      late VoidCallback drain;
      final pacer = PublicationPacer(
        scheduleFrameCallback: (cb) => drain = cb,
        perFrame: 10,
        perFrameBytes: 100,
        isSelected: (id) => id == 'selected',
      );
      // Spend the frame's byte budget on an ordinary entry first.
      pacer.submit(
        id: 'ordinary',
        rank: 5,
        byteCost: 100,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add('ordinary'),
      );
      drain();
      expect(published, ['ordinary'], reason: 'fixture guard: the budget is '
          'actually spent, so TC-1291 is not passing on an empty frame');

      pacer.submit(
        id: 'selected',
        rank: 0,
        byteCost: 10 * 1000 * 1000,
        exempt: true,
        stillValid: () => true,
        publish: () => published.add('selected'),
      );
      expect(
        published,
        ['ordinary', 'selected'],
        reason: 'Step 9.2: the user\'s own item must never wait a frame for '
            'its pixels. The exempt branch returns before the queue, so it '
            'is charged against neither budget -- a property to PIN, not to '
            'change. This is a regression pin, not red-first evidence: it '
            'passes on the pre-change tree too.',
      );
    });

    test('TC-1292: the parked-bytes gauge reports the queue (REPORT only)',
        () {
      late VoidCallback drain;
      final pacer = PublicationPacer(
        scheduleFrameCallback: (cb) => drain = cb,
        perFrame: 1,
        perFrameBytes: 1000,
        maxQueued: 4,
        isSelected: (_) => false,
      );
      expect(pacer.debugQueuedBytes, 0);
      expect(pacer.debugMaxQueuedBytes, 0);

      for (final id in ['a', 'b', 'c']) {
        pacer.submit(
          id: id,
          rank: 0,
          byteCost: 700,
          exempt: false,
          stillValid: () => true,
          publish: () {},
        );
      }
      expect(pacer.debugQueuedBytes, 2100, reason: 'three parked entries');
      expect(pacer.debugMaxQueuedBytes, 2100);

      drain();
      // perFrame: 1 publishes one; the high-water mark must NOT fall back with
      // the live gauge -- a high-water that tracks the current value is a
      // gauge, not a mark, and would read low for exactly the clump it exists
      // to report.
      expect(pacer.debugQueuedBytes, 1400);
      expect(
        pacer.debugMaxQueuedBytes,
        2100,
        reason: 'high-water MARK, not a current-value gauge. No bound is '
            'asserted anywhere here: under the 2026-09-12 option A ruling '
            'parked bytes are REPORTED, never capped.',
      );
    });

    // TC-1293 -- the frozen spec's mechanical acceptance 2, encoded WITH its
    // documented exception: a frame may exceed the quota when its FIRST entry
    // alone exceeded it (the escape hatch; without the exception the assertion
    // would fail for a reason that is by design).
    test('TC-1293: across a burst, no frame publishes more than the quota '
        'unless its first entry alone exceeded it', () {
      // FAMILY B (display): this models PUBLISHED frames, and published bytes
      // are upconverted RGBA. Self-consistent either way, but since mem8 T15b
      // the two families differ numerically, so a family-A label in a
      // family-B role is a future red waiting for the next constant move.
      const quota = 2 * kNominalFullFrameDisplayBytes;
      final published = <String>[];
      late VoidCallback drain;
      final pacer = PublicationPacer(
        scheduleFrameCallback: (cb) => drain = cb,
        // The COUNT budget is deliberately wide open, so anything that stops a
        // drain is the BYTE budget. With perFrame small this test would pass
        // without any byte quota at all -- an assertion that cannot fail.
        perFrame: 100,
        perFrameBytes: quota,
        maxQueued: 100,
        isSelected: (_) => false,
      );
      for (var i = 0; i < 9; i++) {
        pacer.submit(
          id: 'f$i',
          rank: i,
          byteCost: kNominalFullFrameDisplayBytes,
          exempt: false,
          stillValid: () => true,
          publish: () => published.add('f$i'),
        );
      }
      final perFrameTotals = <int>[];
      for (var frame = 0; frame < 9 && published.length < 9; frame++) {
        final before = published.length;
        drain();
        expect(published.length, greaterThan(before),
            reason: 'fixture guard: every frame must make progress, or this '
                'loop is measuring a stalled pacer rather than a paced burst');
        perFrameTotals.add(pacer.debugBytesPublishedLastFrame);
      }
      expect(published.length, 9, reason: 'pacing decides WHEN, never '
          'WHETHER: all nine must publish');
      for (final total in perFrameTotals) {
        expect(total, lessThanOrEqualTo(quota));
      }
      expect(perFrameTotals.length, 5,
          reason: '9 nominal frames at 2 per frame = 5 frames. A single frame '
              'here would mean the byte budget never bound anything.');
      // REPORTED, never asserted against a bound (option A ruling):
      // ignore: avoid_print
      print('TC-1293 report: debugMaxQueuedBytes=${pacer.debugMaxQueuedBytes} '
          'over a 9-frame burst (parked bytes are bounded by maxQueued as a '
          'COUNT, not by perFrameBytes -- SR-5 claims no saving here)');
    });
  });
}
