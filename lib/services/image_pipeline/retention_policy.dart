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

/// Cores one expensive (real RAW) decode occupies.
///
/// Measured 4.666 on a 28-core (20P+8E) machine, differenced across two runs to
/// cancel Dart VM startup: docs/logs/2026-08-30/decode-cpu-parallelism.txt:113.
/// Rounded UP, so the clamp below errs toward fewer concurrent decodes.
const int kCoresPerDecode = 5;

/// Hard cap on lane width, regardless of how large the machine is.
const int kMaxDecodeLaneWidth = 5;

/// Width a machine gets before the user touches the setting (capped by ceiling).
///
/// Was 3 at authoring time; lowered to 1 per the pre-registered Sec 9.3
/// verdict rule after the post-landing re-benchmark measured
/// Speedup(3) = 1.167 < 1.3 on a 28-core/256 GiB machine
/// (docs/logs/2026-08-30/decode-lane-width-sweep.txt). The setting stays
/// user-adjustable up to [laneCeilingFor]'s ceiling; it is just no longer
/// on by default.
const int kDefaultDecodeLaneWidth = 1;

/// How many expensive decodes may run at once on this machine.
///
/// Two independent ceilings, minimum wins:
///   * MEMORY -- each in-flight decode transiently peaks at ~3x the full-res
///     RGBA size (~275 MiB for the 91.55 MiB 24MP entry of cache_budget.dart),
///     so the rung caps it at 2 / 4 / 5. Thresholds are SHARED with
///     [retentionPolicyFor] so the two mechanisms cannot disagree.
///   * CPU -- [kCoresPerDecode] each, capped at [kMaxDecodeLaneWidth]. An
///     8-core machine gets 1, i.e. exactly the pre-2026-08-30 behaviour.
int laneCeilingFor({int? physicalMemoryBytes, required int processors}) {
  final byMemory =
      physicalMemoryBytes == null || physicalMemoryBytes < kMidRungTriggerBytes
      ? 2
      : physicalMemoryBytes < kHighRungTriggerBytes
      ? 4
      : 5;
  final byCpu = (processors ~/ kCoresPerDecode).clamp(1, kMaxDecodeLaneWidth);
  return byMemory < byCpu ? byMemory : byCpu;
}

/// The shipped default for a machine whose ceiling is [ceiling].
int defaultLaneWidthFor(int ceiling) =>
    ceiling < kDefaultDecodeLaneWidth ? ceiling : kDefaultDecodeLaneWidth;
