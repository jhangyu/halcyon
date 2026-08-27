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
/// The rung DEPTHS are byte arithmetic, not UI measurement -- UI measurement
/// in this repo is the user's to run. They are deliberately conservative
/// (at most 384 MiB of held `Uint8List`) and are expected to be tuned.
RetentionPolicy retentionPolicyFor({int? physicalMemoryBytes}) {
  if (physicalMemoryBytes == null ||
      physicalMemoryBytes < kMidRungTriggerBytes) {
    return const RetentionPolicy.floor();
  }
  if (physicalMemoryBytes < kHighRungTriggerBytes) {
    // 12 slots -> 268.80 MiB required, 304 MiB budgeted.
    return const RetentionPolicy(
      before: 3,
      after: 8,
      payloadByteBudget: 304 * 1024 * 1024,
    );
  }
  // 15 slots -> 336.00 MiB required, 384 MiB budgeted.
  return const RetentionPolicy(
    before: 3,
    after: 11,
    payloadByteBudget: 384 * 1024 * 1024,
  );
}
