import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

const int _gib = 1024 * 1024 * 1024;

/// Same shape as the existing payload-cache tests' `encoded()` helper: the
/// cache reads [SourcePayload.byteCost] and nothing else.
EncodedPayload _payload({required int bytes}) => EncodedPayload(
  Uint8List(bytes),
);

Future<NativeImageResult> _bytesLoader(
  String path, {
  required ImageRequestPurpose purpose,
}) async => NativeImageBytes(Uint8List.fromList(<int>[1, 2, 3, 4]));

void main() {
  test('TC-441 each tier maps to its shipped rung, and RAM selection agrees', () {
    expect(
      retentionPolicyForTier(RetentionTier.conservative),
      const RetentionPolicy(
        before: 3,
        after: 5,
        payloadByteBudget: 224 * 1024 * 1024,
      ),
    );
    expect(
      retentionPolicyForTier(RetentionTier.balanced),
      const RetentionPolicy(
        before: 3,
        after: 8,
        payloadByteBudget: 304 * 1024 * 1024,
      ),
    );
    expect(
      retentionPolicyForTier(RetentionTier.generous),
      const RetentionPolicy(
        before: 3,
        after: 11,
        payloadByteBudget: 384 * 1024 * 1024,
      ),
    );

    expect(
      retentionPolicyFor(physicalMemoryBytes: null),
      retentionPolicyForTier(RetentionTier.conservative),
    );
    expect(
      retentionPolicyFor(physicalMemoryBytes: 8 * _gib),
      retentionPolicyForTier(RetentionTier.conservative),
    );
    expect(
      retentionPolicyFor(physicalMemoryBytes: 16 * _gib),
      retentionPolicyForTier(RetentionTier.balanced),
    );
    expect(
      retentionPolicyFor(physicalMemoryBytes: 64 * _gib),
      retentionPolicyForTier(RetentionTier.generous),
    );
  });

  test('TC-442 tierForPolicy round-trips, and unknown policies fall back', () {
    for (final tier in RetentionTier.values) {
      expect(tierForPolicy(retentionPolicyForTier(tier)), tier);
    }
    expect(
      tierForPolicy(
        const RetentionPolicy(before: 1, after: 1, payloadByteBudget: 1),
      ),
      RetentionTier.conservative,
    );
    expect(retentionTierFromId('balanced'), RetentionTier.balanced);
    expect(retentionTierFromId('nonsense'), isNull);
    expect(RetentionTier.generous.id, 'generous');
    expect(RetentionTier.generous.label, 'Generous');
  });

  test('TC-443 shrinking the byte budget evicts immediately, without a put', () {
    final cache = PhotoPayloadCache(byteBudget: 300);
    cache.put('a', _payload(bytes: 100));
    cache.put('b', _payload(bytes: 100));
    cache.put('c', _payload(bytes: 100));
    cache.setEvictionPriority(['c', 'b', 'a']); // c nearest, a farthest
    expect(cache.length, 3);

    cache.setByteBudget(150);

    expect(cache.byteBudget, 150);
    expect(cache.totalByteCost, lessThanOrEqualTo(150));
    expect(cache.contains('c'), isTrue, reason: 'nearest survives');
  });

  test('TC-444 setRetention updates the window and the cache budget', () {
    final controller = ImagePreloadController(
      imageLoader: _bytesLoader,
      payloadEncoder: null,
    );
    expect(controller.retention, const RetentionPolicy.floor());

    controller.setRetention(retentionPolicyForTier(RetentionTier.generous));

    expect(controller.retention.after, 11);
    expect(controller.debugPayloadCacheByteBudget, 384 * 1024 * 1024);
  });
}
