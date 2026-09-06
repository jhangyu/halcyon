import 'package:flutter/foundation.dart';

/// Who currently owns the right to produce a payload for an id.
///
/// The three values are the three code contexts that can hold the claim, not
/// three kinds of work: [producer] is whichever `_ensurePayload` invocation
/// took it, [laneQueue] is the pending `DecodeLane` entry the work was handed
/// to, and [offLaneEncode] is the `_finishOffLane` continuation.
enum PayloadClaimOwner { producer, laneQueue, offLaneEncode }

/// One id's production claim.
class PayloadClaim {
  PayloadClaim({
    required this.id,
    required PayloadClaimOwner owner,
    required this.generation,
  }) : _owner = owner;

  final String id;

  /// The registry generation this claim was acquired in. A claim from an older
  /// generation survived a [PayloadClaimRegistry.clear] and is inert.
  final int generation;

  PayloadClaimOwner get owner => _owner;
  PayloadClaimOwner _owner;

  int get transferCount => _transferCount;
  int _transferCount = 0;
}

/// The one place the pipeline decides WHO MAY PRODUCE a payload.
///
/// Replaces the bare `Set<String> _loadingKeys`: same membership at every
/// instant, plus an owner tag and an assertion at every hand-off.
///
/// ENFORCEMENT IS ASSERT-ONLY. Every guard here compiles out of release
/// builds, so this class introduces no production behaviour change. Flutter
/// runs tests in debug mode, which is what makes those assertions load-bearing
/// in `flutter test`. A runtime throw would be worse than the bug it reports:
/// the release sites live inside `unawaited` continuations, where a throw is an
/// unhandled async error rather than a caught one.
class PayloadClaimRegistry {
  final Map<String, PayloadClaim> _claims = <String, PayloadClaim>{};

  /// Ids handed to the lane whose lane body has not re-entered yet. Debug-only
  /// bookkeeping for [debugDuplicateProducerCount]; it never gates anything.
  final Set<String> _awaitingLane = <String>{};

  int _generation = 0;
  int get generation => _generation;

  int _duplicateProducerCount = 0;

  int get length => _claims.length;
  Iterable<String> get heldIds => _claims.keys;

  bool isHeld(String id) => _claims.containsKey(id);
  PayloadClaimOwner? ownerOf(String id) => _claims[id]?.owner;

  /// Takes the claim for [id]. Asserts nobody already holds it -- THE
  /// double-hold guard.
  PayloadClaim acquire(
    String id, {
    PayloadClaimOwner owner = PayloadClaimOwner.producer,
  }) {
    final existing = _claims[id];
    assert(
      existing == null,
      'DOUBLE HOLD: $id is already claimed by ${existing.owner}; '
      '$owner tried to acquire it. Two producers for one id means a duplicate '
      'decode and an orphaned tier-1 ImageCache key.',
    );
    if (owner == PayloadClaimOwner.producer && _awaitingLane.contains(id)) {
      // Reachable and TOLERATED today: the claim is dropped at the lane
      // hand-off, so a concurrent pass can legitimately become a second
      // producer before the lane body runs. Counted, never asserted -- closing
      // this window would override the G-023 ruling.
      _duplicateProducerCount++;
      debugPrint('halcyon.claim.dup|id=$id|awaitingLane=true');
    }
    final claim =
        PayloadClaim(id: id, owner: owner, generation: _generation);
    _claims[id] = claim;
    return claim;
  }

  /// Moves the claim for [id] from [from] to [to] without releasing it.
  void transfer(
    String id, {
    required PayloadClaimOwner from,
    required PayloadClaimOwner to,
  }) {
    final claim = _claims[id];
    assert(
      claim != null,
      'TRANSFER OF NOTHING: $id has no claim; $from tried to hand it to $to.',
    );
    assert(
      claim == null || claim.owner == from,
      'WRONG OWNER: $id is owned by ${claim.owner}, not $from '
      '(attempted transfer to $to).',
    );
    if (claim == null) return;
    claim._owner = to;
    claim._transferCount++;
  }

  /// The lane hand-off: asserts ownership, then DROPS the claim.
  ///
  /// Behaviour-preserving by construction. The lane body re-enters
  /// `_ensurePayload` for this same id, and a claim still held at that moment
  /// would send it down the in-flight early-resolve branch: it parks nothing,
  /// produces nothing, and the item strands on a permanent spinner.
  void handOffToLane(String id, {required PayloadClaimOwner from}) {
    final claim = _claims[id];
    assert(
      claim != null,
      'HAND-OFF OF NOTHING: $id has no claim to hand to the lane.',
    );
    assert(
      claim == null || claim.owner == from,
      'WRONG OWNER: $id is owned by ${claim.owner}, not $from '
      '(attempted lane hand-off).',
    );
    _claims.remove(id);
    _awaitingLane.add(id);
  }

  /// The lane body arriving. Returns whether [id] was awaiting a lane body.
  bool assumeFromLane(String id) => _awaitingLane.remove(id);

  /// Releases [id]. Returns false when there was nothing to release.
  ///
  /// Absence is TOLERATED, never asserted: `_finishOffLane` is unawaited by
  /// design and can outlive a `reset()`/`dispose()` that cleared the registry.
  /// Same shape as `InflightBytesBudget`'s epoch (BUG 2026-09-03, TC-886) --
  /// a stale release is a no-op, not an over-release.
  bool release(String id, {required PayloadClaimOwner by}) {
    final claim = _claims[id];
    if (claim == null) return false;
    if (claim.generation != _generation) {
      _claims.remove(id);
      return false;
    }
    assert(
      claim.owner == by,
      'WRONG OWNER: $id is owned by ${claim.owner}; $by tried to release it. '
      'Releasing another party\'s claim lets a second producer start while the '
      'first is still working.',
    );
    _claims.remove(id);
    return true;
  }

  /// Folder switch / dispose. Every in-flight claim becomes inert.
  void clear() {
    _claims.clear();
    _awaitingLane.clear();
    _generation++;
  }

  /// Count of producers that acquired an id while it was awaiting a lane body.
  /// An OBSERVATION, not a guard -- see [acquire].
  int get debugDuplicateProducerCount => _duplicateProducerCount;

  @visibleForTesting
  bool debugIsAwaitingLane(String id) => _awaitingLane.contains(id);

  @visibleForTesting
  void debugResetCounters() {
    _duplicateProducerCount = 0;
    _awaitingLane.clear();
  }
}
