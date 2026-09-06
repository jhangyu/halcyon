/// Width of every bounded stage that is NOT the decode lane.
///
/// Pinned at 2 in this revision (`EncodeStage`'s and `DeriveQueue`'s shipped
/// constructor defaults), deliberately: P2's deliverable is that ONE function
/// decides all three numbers, not a new tuning knob. A future ratio rule goes
/// in [StageWidths.derive] and nowhere else.
const int kSecondaryStageWidth = 2;

/// The widths of every bounded stage in the image pipeline, derived from the
/// one configured number (`AppState.decodeLaneWidth`, pref `decodeLaneWidth`).
///
/// Exists so "two stages disagree about how wide the pipeline is" is
/// unrepresentable: there is one input, one derivation, and one push
/// (`ImagePreloadController._applyStageWidths`). Throttles are NOT pools and
/// are deliberately absent here (binding user ruling 2026-09-06): tier-1 /
/// tier-2 publication pacing bounds work per FRAME, not work in flight, and
/// folding it into a width would make one number mean two things.
class StageWidths {
  const StageWidths({
    required this.decodeLane,
    required this.encode,
    required this.derive,
  });

  /// The ONE derivation. Clamps its input exactly once, here, so each stage's
  /// own `value < 1 ? 1 : value` guard is a no-op rather than a second,
  /// differently-shaped clamp.
  ///
  /// LOWER BOUND ONLY (lead ruling 2026-09-06). An earlier revision also
  /// clamped to `kMaxDecodeLaneWidth`, which broke TC-966
  /// (`decode_pool_wiring_test.dart`): that test pins "clamps exactly once"
  /// to mean the `< 1` guard alone, and asserts a requested width of 9
  /// reaches the lane as 9. Capping the user's setting is `AppState`'s job,
  /// where the persisted preference is read; duplicating it here would make
  /// the ceiling live in two places and silently narrow the lane below what
  /// the caller asked for.
  factory StageWidths.derive(int decodeLaneWidth) => StageWidths(
    decodeLane: decodeLaneWidth < 1 ? 1 : decodeLaneWidth,
    encode: kSecondaryStageWidth,
    derive: kSecondaryStageWidth,
  );

  /// Bound on concurrent real (RAW) decodes; also sizes the native decode pool.
  final int decodeLane;

  /// Bound on concurrent JPEG/WebP re-encodes (`EncodeStage`).
  final int encode;

  /// Bound on concurrent sidebar tile derivations (`DeriveQueue`).
  final int derive;

  @override
  bool operator ==(Object other) =>
      other is StageWidths &&
      other.decodeLane == decodeLane &&
      other.encode == encode &&
      other.derive == derive;

  @override
  int get hashCode => Object.hash(decodeLane, encode, derive);

  @override
  String toString() =>
      'StageWidths(decodeLane: $decodeLane, encode: $encode, derive: $derive)';
}
