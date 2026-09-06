import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/preload_fixtures.dart';

/// Contract `docs/logs/2026-09-06/sidebar-fix-and-async-plan-contract.md` D1:
/// AC1 (visible-before-margin) and AC2 (priority-freeze fix).
///
/// Both tests gate the decoder so lane entries stay PENDING after the sweep's
/// 100ms debounce fires, letting [ImagePreloadController.debugLanePendingPriorityFor]
/// observe the priority DecodeLane actually queued each key at.
Future<NativeImageResult> _rawLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _tiny() {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 8, height: 8);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-963 (AC1): every visible row's lane priority must strictly outrank
  // every margin row's. Old formula `(index - safeStart).abs()` measured from
  // the TOP of the range with no floor for margin rows, so with a 41-row
  // visible range [100, 140] a margin row just 10 slots above the top
  // (index 90, old rowDistance 10) outranked the visible range's OWN far end
  // (index 140, old rowDistance 40) -- exactly the bug this AC proves fixed.
  test(
    'every visible row outranks every margin row (D1 two-part rowDistance)',
    () async {
      final gate = Completer<void>();
      final controller = ImagePreloadController(
        imageLoader: _rawLoader,
        dngDecoder: (path) async {
          await gate.future;
          return _tiny();
        },
        payloadEncoder: null,
        decodeLaneWidth: 1,
      );
      final items = photoItems(400, extension: 'arw');
      controller.updateTargetSize(800, 600);

      const safeStart = 100;
      const safeEnd = 140; // 41-row visible range; margin is 20 rows each side.
      await controller.preloadThumbnails(
        items: items,
        startIdx: safeStart,
        endIdx: safeEnd,
        notifyLoaded: () {},
      );
      // Let the sweep's 100ms debounce fire and enqueue every row.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final visibleIds = [
        for (var i = safeStart; i <= safeEnd; i++) 'p$i',
      ];
      final marginIds = [
        for (var i = safeStart - 20; i < safeStart; i++) 'p$i',
        for (var i = safeEnd + 1; i <= safeEnd + 20; i++) 'p$i',
      ];

      // decodeLaneWidth is clamped to a minimum of 1 (decode_lane.dart:75), so
      // exactly one task is always IN FLIGHT (removed from the pending map,
      // not merely queued) rather than pending. Whichever row the scheduler
      // picked first is the globally lowest-priority row, so a visible id
      // reading null here is EXPECTED and only strengthens the claim (it
      // ranked ahead of everything, including every other visible row); a
      // margin id reading null would mean a margin row started ahead of some
      // visible row, which is the bug itself, so that stays a hard failure.
      final visiblePriorities = <int>[
        for (final id in visibleIds)
          if (controller.debugLanePendingPriorityFor(id) != null)
            controller.debugLanePendingPriorityFor(id)!,
      ];
      final marginPriorities = <int>[];
      for (final id in marginIds) {
        final priority = controller.debugLanePendingPriorityFor(id);
        expect(
          priority,
          isNotNull,
          reason: '$id must still be pending, never the row picked to run first',
        );
        marginPriorities.add(priority!);
      }
      expect(
        visiblePriorities,
        isNotEmpty,
        reason: 'at least one visible row must still be observably pending',
      );

      final worstVisible = visiblePriorities.reduce((a, b) => a > b ? a : b);
      final bestMargin = marginPriorities.reduce((a, b) => a < b ? a : b);
      expect(
        worstVisible,
        lessThan(bestMargin),
        reason:
            'every visible row must strictly outrank every margin row; '
            'worst visible priority=$worstVisible, best margin priority=$bestMargin',
      );

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      controller.dispose();
    },
  );

  // TC-964 (AC2): once a sidebar row is already pending, a later sweep whose
  // visible range has moved must UPDATE (not freeze) its priority to reflect
  // the new range. The old `if (!isPending(key))` guard skipped re-enqueueing
  // any key already pending, so a row's priority stayed pinned to whatever
  // distance-from-old-range it first queued at.
  test(
    'an already-pending sidebar row is reprioritised when the visible range moves',
    () async {
      final gate = Completer<void>();
      final controller = ImagePreloadController(
        imageLoader: _rawLoader,
        dngDecoder: (path) async {
          await gate.future;
          return _tiny();
        },
        payloadEncoder: null,
        decodeLaneWidth: 1,
      );
      final items = photoItems(400, extension: 'arw');
      controller.updateTargetSize(800, 600);

      // First sweep: p150 sits at the far edge of a wide visible range, so it
      // is queued at a large distance-from-center.
      await controller.preloadThumbnails(
        items: items,
        startIdx: 100,
        endIdx: 150,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final firstPriority = controller.debugLanePendingPriorityFor('p150');
      expect(firstPriority, isNotNull, reason: 'p150 should be pending after sweep 1');
      expect(
        firstPriority,
        greaterThan(kSidebarPayloadPriorityBase),
        reason: 'p150 is not at the exact center of [100,150]',
      );

      // Second sweep: the visible range moves so p150 is now dead center.
      // Its priority must improve (become numerically smaller), proving the
      // pending entry was re-enqueued rather than left frozen.
      await controller.preloadThumbnails(
        items: items,
        startIdx: 148,
        endIdx: 152,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final secondPriority = controller.debugLanePendingPriorityFor('p150');
      expect(
        secondPriority,
        isNotNull,
        reason: 'p150 should still be pending (decoder gated) after sweep 2',
      );
      expect(
        secondPriority,
        equals(kSidebarPayloadPriorityBase),
        reason:
            'p150 is now the exact center of [148,152] so its rowDistance '
            'must be 0 -- proves the priority was updated, not frozen at '
            '$firstPriority',
      );
      expect(
        secondPriority,
        lessThan(firstPriority!),
        reason: 'priority must improve (numerically decrease) once p150 '
            'becomes the visible center instead of a far edge',
      );

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      controller.dispose();
    },
  );
}
