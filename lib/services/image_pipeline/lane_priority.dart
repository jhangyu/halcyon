/// THE one place lane priorities are decided (async-pipeline-refactor-plan.md
/// §3 Phase 4).
///
/// Before this file the three producers each did their own arithmetic against
/// their own base constant, and the only thing keeping them in the ruled order
/// was that nobody had yet written a distance big enough to punch through a
/// base gap of 1000. This file makes the ordering a property of one pure
/// function instead of a coincidence of three call sites.
///
/// ## The bands, in the ruled order
///
/// | Band | Base | What |
/// |---|---|---|
/// | [LaneGroup.selected] (P1) | 0 | the item the user is looking at |
/// | [LaneGroup.navigationWindow] (P2) | 1000 | the rest of the retention window |
/// | [LaneGroup.fullRes] | 2000 | tier-2 full-resolution upgrades |
/// | [LaneGroup.sidebarVisible] (P3) | 3000 | sidebar rows on screen |
/// | [LaneGroup.sidebarMargin] (P4) | 4000 | sidebar prefetch rows off screen |
///
/// The full-res band sits BETWEEN payload production and sidebar work, not
/// above everything. That placement is a user ruling (2026-08-26, recorded at
/// `decode_lane.dart`'s old `kFullResPriorityBase` doc and re-affirmed as
/// override S4 of `docs/logs/2026-09-06/async-refactor-execution-contract.md`):
/// the blank slots the user can SEE go first, so any pending payload
/// production outranks every full-resolution upgrade, and a still-window-
/// resolution main image is a bigger incompleteness than a blank sidebar tile.
/// The refactor plan's own sentence "full-res gets its own base above P4" is
/// explicitly NOT executed; changing this order needs a user decision, not a
/// refactor.
///
/// ## Why the within-group distance is clamped
///
/// Base spacing alone is not a guarantee. Retention distances are tiny (max 11
/// on the generous tier), but a sidebar VISIBLE range is bounded only by the
/// window height and the folder size — nothing in the code stops it exceeding
/// [kLaneBandGap] rows, and a row at distance >= 1000 in the P3 band would
/// outrank the full-res band it must never reach. The plan offered "clamp" or
/// "widen the gap" and chose to widen; this file does BOTH, because the gap is
/// an assumption about data ([kLaneBandGap] rows never visible at once) while
/// the clamp is an invariant of the code. The cost is that two rows further
/// than [kMaxWithinGroupDistance] apart can tie; ties inside one band are
/// harmless (the lane is stable for equal priorities) whereas a punch-through
/// between bands is a user-visible ordering defect.
library;

/// The gap between two adjacent bands, and therefore the exclusive upper bound
/// on any within-group distance.
const int kLaneBandGap = 1000;

/// The largest within-group distance that can never punch through the band
/// above. Distances are clamped to this value.
const int kMaxWithinGroupDistance = kLaneBandGap - 1;

/// What a piece of lane work is FOR, in the order it is served.
///
/// The enum's declaration order IS the priority order: [lanePriorityFor]
/// derives each band's base from [LaneGroup.index], so a band cannot be given
/// a base that contradicts its position in this list.
enum LaneGroup {
  /// P1 — payload production for the selected item.
  selected,

  /// P2 — payload production for the rest of the retention window.
  navigationWindow,

  /// Tier-2 full-resolution upgrade. Between P2 and P3 by user ruling; see
  /// the library doc above.
  fullRes,

  /// P3 — payload production the sidebar asked for, for a row on screen.
  ///
  /// USER RULING 2026-08-30 (contract D5), carried here verbatim in substance
  /// from the constant this band replaces: scrolling fills the payload cache,
  /// so the sidebar MAY ask for payloads — and it asks LAST. A blank sidebar
  /// tile is a smaller incompleteness than the main image still being at
  /// window resolution, and every row the user is about to SELECT is covered
  /// by the waiter path instead, which costs nothing.
  ///
  /// Sidebar work is deliberately NOT a separate [LaneTaskKind]: the lane key
  /// stays `(payload, id)`, so a navigation enqueue for the same item REPLACES
  /// this entry and promotes it, instead of decoding the same file twice under
  /// two keys. That replacement is exactly what TC-983 asserts in both
  /// directions.
  sidebarVisible,

  /// P4 — payload production the sidebar asked for, for an off-screen
  /// prefetch (margin) row.
  sidebarMargin,
}

/// The base priority of [group]: strictly increasing with the enum's order.
int laneBaseFor(LaneGroup group) => group.index * kLaneBandGap;

/// The lane priority for a piece of work in [group] at [withinGroupDistance].
///
/// [withinGroupDistance] must be non-negative; it is clamped to
/// [kMaxWithinGroupDistance] so no group's work can ever reach the next
/// group's base. Lower is served first.
int lanePriorityFor({
  required LaneGroup group,
  required int withinGroupDistance,
}) {
  assert(
    withinGroupDistance >= 0,
    'within-group distance must be non-negative, got $withinGroupDistance',
  );
  final d = withinGroupDistance.clamp(0, kMaxWithinGroupDistance);
  return laneBaseFor(group) + d;
}

/// Classifies a NAVIGATION payload enqueue.
///
/// [signedDistance] is the signed offset from the selected index (negative =
/// before it). The within-group rank keeps the user-ruled near-to-far walk
/// (0, +1, -1, +2, -2, ...) via [laneRankForDistance]: forward slots win ties
/// against the mirrored backward slot because navigation is predominantly
/// forward.
int navigationPriorityFor(int signedDistance) => signedDistance == 0
    ? lanePriorityFor(group: LaneGroup.selected, withinGroupDistance: 0)
    : lanePriorityFor(
        group: LaneGroup.navigationWindow,
        withinGroupDistance: laneRankForDistance(signedDistance),
      );

/// The full-resolution upgrade priority for an item at [signedDistance] from
/// the selection.
int fullResPriorityFor(int signedDistance) => lanePriorityFor(
  group: LaneGroup.fullRes,
  withinGroupDistance: laneRankForDistance(signedDistance),
);

/// Classifies a SIDEBAR payload enqueue for the row at [index], given the
/// visible range `[safeStart, safeEnd]`.
///
/// A visible row ranks by distance from the visible CENTRE; a margin row ranks
/// in its own band by distance from the nearest visible EDGE. This is the
/// landed D1 behaviour (contract 2026-09-06), re-expressed: D1 got "every
/// visible row outranks every margin row" by adding a synthetic
/// `marginDistanceBase` derived from the visible span, because it had only one
/// band to work with. With P3 and P4 as real bands the synthetic offset is no
/// longer needed — the band boundary does that job — and, unlike the offset,
/// the boundary cannot be out-run by a tall viewport.
int sidebarPriorityFor({
  required int index,
  required int safeStart,
  required int safeEnd,
}) {
  if (index >= safeStart && index <= safeEnd) {
    final centre = (safeStart + safeEnd) ~/ 2;
    return lanePriorityFor(
      group: LaneGroup.sidebarVisible,
      withinGroupDistance: (index - centre).abs(),
    );
  }
  final edgeDistance = index < safeStart ? safeStart - index : index - safeEnd;
  return lanePriorityFor(
    group: LaneGroup.sidebarMargin,
    withinGroupDistance: edgeDistance,
  );
}

/// The near-to-far rank of a signed distance: 0, +1, -1, +2, -2, ... maps to
/// 0, 1, 2, 3, 4, ...
///
/// Moved here verbatim from `decode_lane.dart`'s `laneRankFor` so that every
/// input to a lane priority comes from this file. `laneRankFor` remains as a
/// deprecated alias for callers outside the pipeline.
int laneRankForDistance(int signedDistance) {
  final d = signedDistance.abs();
  if (d == 0) return 0;
  return signedDistance > 0 ? 2 * d - 1 : 2 * d;
}

/// True when [priority] belongs to the sidebar's own bands (P3/P4).
///
/// The sidebar's conditional re-enqueue (G-027) turns on exactly this
/// question: a pending `(payload, id)` entry may be re-ranked when the sidebar
/// itself put it there, and must NEVER be re-ranked when navigation did --
/// re-enqueueing a navigation entry at a sidebar priority demotes the item the
/// user is looking at. Expressed here rather than as a `>=` comparison at the
/// call site so that the band table and the predicate over it cannot drift
/// apart.
bool isSidebarPriority(int priority) =>
    priority >= laneBaseFor(LaneGroup.sidebarVisible);

/// Base of the sidebar's VISIBLE band.
///
/// Kept under its historical name because it is the symbol the sidebar
/// ordering tests (TC-963/TC-964) assert against; those tests pin RELATIVE
/// order through this symbol and must survive the rebasing verbatim.
const int kSidebarPayloadPriorityBase = 3 * kLaneBandGap;

/// Base of the full-resolution band. Historical name, new value; see the
/// library doc for why it sits between P2 and P3.
const int kFullResPriorityBase = 2 * kLaneBandGap;
