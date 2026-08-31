import 'photo_payload_cache.dart';

/// A machine gets the mid rung at or above this much RAM.
const int kMidRungTriggerBytes = 12 * 1024 * 1024 * 1024;

/// A machine gets the high rung at or above this much RAM.
const int kHighRungTriggerBytes = 32 * 1024 * 1024 * 1024;

/// How much the payload cache keeps, and how far forward it reaches.
///
/// The floor rung is EXACTLY the constants this app has always shipped
/// ([kRetentionBefore] / [kRetentionAfter] / [kPayloadByteBudget]); a machine
/// with no memory reading -- which is every platform except macOS today --
/// behaves byte-for-byte as it did before this type existed.
class RetentionPolicy {
  const RetentionPolicy({
    required this.before,
    required this.after,
    required this.payloadByteBudget,
  });

  /// The shipped floor. Referenced, not re-typed, so the two cannot drift.
  const RetentionPolicy.floor()
    : before = kRetentionBefore,
      after = kRetentionAfter,
      payloadByteBudget = kPayloadByteBudget;

  final int before;
  final int after;
  final int payloadByteBudget;

  @override
  bool operator ==(Object other) =>
      other is RetentionPolicy &&
      other.before == before &&
      other.after == after &&
      other.payloadByteBudget == payloadByteBudget;

  @override
  int get hashCode => Object.hash(before, after, payloadByteBudget);

  @override
  String toString() =>
      'RetentionPolicy(-$before..+$after, $payloadByteBudget B)';
}

/// Sizes retention from total physical memory.
///
/// [before] never grows: back-navigation is the rare direction, so widening
/// backward buys the least per byte held. Each rung's budget is
/// `slots * 22.4 MiB * 1.11` rounded up to a whole MiB -- the same derivation
/// that produced the shipped 224 MiB (photo_payload_cache.dart:19-30), where
/// 22.4 MiB is the measured window-resolution RGBA cost of one no-preview RAW
/// item and the 11% is headroom above the row the cache must hold.
///
/// AMENDMENT (Phase 13, AD-040): the 22.4 MiB figure above now describes only
/// the encode-failure fallback path. A re-encoded RAW payload retains one
/// full-resolution JPEG; this budget is deliberately NOT re-derived in that phase.
///
/// The rung DEPTHS are byte arithmetic, not UI measurement -- UI measurement
/// in this repo is the user's to run. They are deliberately conservative
/// (at most 512 MiB of held `Uint8List`) and are expected to be tuned.
RetentionPolicy retentionPolicyFor({int? physicalMemoryBytes}) =>
    retentionPolicyForTier(
      retentionTierFor(physicalMemoryBytes: physicalMemoryBytes),
    );

/// The three shipped retention rungs, as user-selectable named tiers.
///
/// This enum, not [retentionPolicyFor], is where the rung values live: RAM
/// selection now picks a TIER and delegates, so the auto-selected policy and a
/// user override can never be two different tables.
enum RetentionTier { conservative, balanced, generous }

extension RetentionTierLabel on RetentionTier {
  String get id => switch (this) {
    RetentionTier.conservative => 'conservative',
    RetentionTier.balanced => 'balanced',
    RetentionTier.generous => 'generous',
  };

  String get label => switch (this) {
    RetentionTier.conservative => 'Conservative',
    RetentionTier.balanced => 'Balanced',
    RetentionTier.generous => 'Generous',
  };
}

/// The tier whose [RetentionTierLabel.id] is [id]; null if unrecognised.
RetentionTier? retentionTierFromId(String id) {
  for (final tier in RetentionTier.values) {
    if (tier.id == id) return tier;
  }
  return null;
}

/// The ONE table of rung values. Derivations for each budget are in the
/// [retentionPolicyFor] doc comment above; they are unchanged.
RetentionPolicy retentionPolicyForTier(RetentionTier tier) => switch (tier) {
  // Exactly the shipped floor, by reference so the two cannot drift.
  RetentionTier.conservative => const RetentionPolicy.floor(),
  // 12 slots -> 268.80 MiB required, 384 MiB budgeted (raised 2026-08-30,
  // AD-042/AD-043; see docs/logs/2026-08-30/cache-rung-raise-rederivation.md).
  RetentionTier.balanced => const RetentionPolicy(
    before: 3,
    after: 8,
    payloadByteBudget: 384 * 1024 * 1024,
  ),
  // 15 slots -> 336.00 MiB required, 512 MiB budgeted (raised 2026-08-30,
  // AD-042/AD-043; see docs/logs/2026-08-30/cache-rung-raise-rederivation.md).
  RetentionTier.generous => const RetentionPolicy(
    before: 3,
    after: 11,
    payloadByteBudget: 512 * 1024 * 1024,
  ),
};

/// Names a policy. Exact value match; anything unrecognised is treated as the
/// most conservative option, which is the only safe direction to guess.
RetentionTier tierForPolicy(RetentionPolicy policy) {
  for (final tier in RetentionTier.values) {
    if (retentionPolicyForTier(tier) == policy) return tier;
  }
  return RetentionTier.conservative;
}

/// Which tier this machine gets before the user touches the setting.
RetentionTier retentionTierFor({int? physicalMemoryBytes}) {
  if (physicalMemoryBytes == null ||
      physicalMemoryBytes < kMidRungTriggerBytes) {
    return RetentionTier.conservative;
  }
  if (physicalMemoryBytes < kHighRungTriggerBytes) {
    return RetentionTier.balanced;
  }
  return RetentionTier.generous;
}

/// Hard cap on lane width, regardless of how large the machine is.
///
/// AD-044 (2026-08-31): the CPU/memory decode-lane capability probe was
/// deleted after failing cross-platform three times -- the last on a
/// 32 GB/8-thread Windows machine, which computed a ceiling of 1 and
/// disabled the slider entirely. Lane width is now a plain user setting:
/// slider 1..8 on every platform, default 2, with no CPU- or memory-derived
/// ceiling anywhere.
const int kMaxDecodeLaneWidth = 8;

/// Width a machine gets before the user touches the setting.
const int kDefaultDecodeLaneWidth = 2;
