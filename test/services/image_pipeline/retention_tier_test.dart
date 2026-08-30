import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

const int _gib = 1024 * 1024 * 1024;

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
}
