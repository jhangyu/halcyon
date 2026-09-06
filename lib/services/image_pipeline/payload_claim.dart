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

  /// The registry generation this claim was acquired in.
  ///
  /// DIAGNOSTIC ONLY -- nothing reads it to make a decision. Staleness is
  /// decided by OBJECT IDENTITY (see [PayloadClaimRegistry.release]), which is
  /// strictly stronger: it also catches a hand-off and re-acquire inside a
  /// single generation, which a generation compare cannot see. Kept because it
  /// tells a debugger which folder-load a stranded claim came from.
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
/// TWO KINDS OF GUARD LIVE HERE, and only one of them is assert-only.
///
///  1. OWNER ASSERTIONS are debug-only. `assert` compiles out of release
///     builds, so every "wrong owner" / "transfer of nothing" check is a
///     development-time protocol alarm and nothing more. Flutter runs tests in
///     debug mode, which is what makes them load-bearing in `flutter test`. A
///     runtime throw would be worse than the bug it reports: these sites live
///     inside `unawaited` continuations, where a throw is an unhandled async
///     error rather than a caught one.
///
///  2. THE IDENTITY GUARDS RUN IN RELEASE and DO change behaviour versus the
///     raw `Set<String>` this replaced. Every mutating verb ([transfer],
///     [handOffToLane], [release]) accepts the [PayloadClaim] its caller was
///     handed and refuses to touch the map when the id is now held by a
///     different claim object. That refusal is the point, not an accident: the
///     bare set matched on id alone, so a continuation that outlived a
///     [clear] (or a lane hand-off and re-acquire) would delete or re-tag a
///     fresh producer's live claim and admit the second producer this class
///     exists to prevent. The guards are cheap, they only ever turn a
///     would-be corruption into a no-op, and they never manufacture a
///     mutation the caller did not ask for.
///
/// So: this class is NOT "zero production behaviour change". It is "no change
/// except refusing stale mutations", which is the fix. Callers with no
/// suspension point between acquiring and mutating may omit the claim and get
/// the old id-only matching.
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
  ///
  /// Pass [claim] for the same reason [release] wants it: a caller that
  /// crossed an await can arrive to find the id re-claimed by somebody else,
  /// and re-tagging a stranger's live claim is the same theft as releasing it.
  void transfer(
    String id, {
    required PayloadClaimOwner from,
    required PayloadClaimOwner to,
    PayloadClaim? claim,
  }) {
    final held = _claims[id];
    if (claim != null && !identical(held, claim)) {
      // STALE: the id belongs to a different claim now. Mutate nothing.
      return;
    }
    assert(
      held != null,
      'TRANSFER OF NOTHING: $id has no claim; $from tried to hand it to $to.',
    );
    assert(
      held == null || held.owner == from,
      'WRONG OWNER: $id is owned by ${held.owner}, not $from '
      '(attempted transfer to $to).',
    );
    if (held == null) return;
    held._owner = to;
    held._transferCount++;
  }

  /// The lane hand-off: asserts ownership, then DROPS the claim.
  ///
  /// Behaviour-preserving by construction. The lane body re-enters
  /// `_ensurePayload` for this same id, and a claim still held at that moment
  /// would send it down the in-flight early-resolve branch: it parks nothing,
  /// produces nothing, and the item strands on a permanent spinner.
  /// Pass [claim] for the same reason [release] wants it, and with more at
  /// stake: this method DELETES the map entry, so a stale caller arriving
  /// after a `clear()` and a fresh `acquire` would drop an innocent producer's
  /// live claim AND arm the awaiting-lane set for an id no lane body is coming
  /// for -- which then miscounts the next producer as a duplicate.
  void handOffToLane(
    String id, {
    required PayloadClaimOwner from,
    PayloadClaim? claim,
  }) {
    final held = _claims[id];
    if (claim != null && !identical(held, claim)) {
      // STALE: not our claim any more. Remove nothing, arm nothing.
      return;
    }
    assert(
      held != null,
      'HAND-OFF OF NOTHING: $id has no claim to hand to the lane.',
    );
    assert(
      held == null || held.owner == from,
      'WRONG OWNER: $id is owned by ${held.owner}, not $from '
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
  /// Same INTENT as `InflightBytesBudget`'s epoch (BUG 2026-09-03, TC-886) --
  /// a stale release is a no-op, not an over-release -- but the mechanism is
  /// object identity, not a monotonic counter. Identity is strictly stronger
  /// here: it also catches a hand-off and re-acquire that happens inside one
  /// generation, which no epoch compare can see.
  ///
  /// THE RELEASER CARRIES ITS OWN CLAIM. Pass the [PayloadClaim] this releaser
  /// was handed by [acquire] or [transfer] and a release is matched by object
  /// identity, so a continuation that outlived a [clear] (or a lane hand-off
  /// and re-acquire) finds the id re-claimed by SOMEBODY ELSE and does nothing
  /// at all. Without it this method has only the id and the owner tag to go
  /// on, and those repeat across generations: a stale `offLaneEncode` release
  /// arriving after a folder switch would trip the wrong-owner assert against
  /// an innocent new producer AND delete that producer's live claim, letting a
  /// second producer in. That is a real behaviour change in a class whose
  /// whole promise is that it makes none, which is why every controller
  /// releaser passes [claim].
  ///
  /// Omitting [claim] keeps the old id+owner matching and is fine for callers
  /// with no suspension point between acquire and release (the registry's own
  /// unit tests).
  bool release(String id, {required PayloadClaimOwner by, PayloadClaim? claim}) {
    final held = _claims[id];
    if (held == null) return false;
    if (claim != null && !identical(held, claim)) {
      // STALE. Note what is NOT done here: the live claim is left alone and no
      // assertion fires. Removing it would be the over-release this tolerance
      // exists to prevent.
      return false;
    }
    assert(
      held.owner == by,
      'WRONG OWNER: $id is owned by ${held.owner}; $by tried to release it. '
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
