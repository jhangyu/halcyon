import 'photo_source.dart';

export 'photo_source.dart' show ProbeResult, SourceCost;

/// How far from the selected item an EXPENSIVE source may be started.
///
/// Verbatim today's RAW behaviour: +/-1, behind the navigation debounce. Nine
/// concurrent FFI decodes on an 8-core machine is not a theoretical worry --
/// it is what a full-window rung would do on arrival, and it would break the
/// instant back/forward navigation that is this app's whole selling point
/// (user decision D2).
const int kExpensiveStartupRadius = 1;

/// How far from the selected item a FULL-SIZE (tier-2) decode is precached.
///
/// **This is deliberately NOT [kExpensiveStartupRadius], and merging the two
/// back into one constant is a silent regression.** Until round 2 a single
/// constant served both meanings, which made "widen the full-size window to
/// +/-2" look like a one-character change. It is not: widening the shared
/// constant would also widen expensive-RAW startup eligibility, putting FIVE
/// items on the sequential RAW rung instead of three -- about 42 s of cold
/// settle instead of 25 s on a no-preview folder, at the measured 8.5 s per
/// expensive settle -- while appearing to implement exactly what was asked.
///
/// The split is required to satisfy two standing rules at once: `+/-1` governs
/// expensive RAW STARTUP eligibility only (never a retention boundary), and
/// sequential RAW decode is unchanged. `test/image_preload_window_test.dart`
/// TC-098 fails if they are ever merged.
///
/// Retention is a third, wider thing again (`-3..+5`): this radius decides only
/// which slots are decoded at FULL size, not which are kept.
const int kTierTwoRadius = 2;

/// Decides WHEN, and in what order, sources are started. The only layer that
/// knows about cost (design §3.3).
///
/// Two rungs, keyed on MEASURED CONTENT:
///
/// | rung        | startup window | debounced |
/// |-------------|----------------|-----------|
/// | `cheap`     | the whole -3..+5 retention window | no  |
/// | `expensive` | +/-1                              | yes |
///
/// This is not the old type branch under a new name. The old rule picked the
/// rung from the file extension and was wrong 13 times in 14; measuring the
/// content moves those 13 onto the cheap rung and shrinks `expensive` from
/// "every DNG" to "files with no usable embedded JPEG at all".
///
/// **Startup is not retention.** An expensive item outside +/-1 but inside
/// -3..+5 keeps its payload; only STARTING one is restricted. That separation
/// is what turns a two-step round trip from two decodes into one.
class PrefetchScheduler {
  /// id -> measured cost. Written at most once per item and cleared only by
  /// [reset] (i.e. a folder reload), so a file is asked about once per folder
  /// rather than once per navigation.
  ///
  /// This is the successor to the old per-item raw-decode map's exactly-once
  /// guarantee (invariant I6), and it is strictly stronger: the old map only existed for
  /// items the native side flagged, so a permanently failing THUMBNAIL was
  /// re-asked on every sweep forever (invariant I8's defect). One memo now
  /// covers raw items, non-raw failures and thumbnails alike.
  final Map<String, SourceCost> _cost = {};

  SourceCost? costOf(String id) => _cost[id];

  bool isKnown(String id) => _cost.containsKey(id);

  /// Records [cost] for [id], first writer wins.
  ///
  /// First-writer-wins matters: the content probe and the bridge answer can
  /// both speak for the same item, and letting a later observation overwrite
  /// an earlier one would make the rung -- and therefore the number of native
  /// calls -- depend on navigation history.
  void observe(String id, SourceCost? cost) {
    if (cost == null) return;
    _cost.putIfAbsent(id, () => cost);
  }

  /// Measures [path] once and memoizes its cost.
  ///
  /// A null cost (unmeasurable content) is NOT memoized: the caller resolves
  /// that case from the first bridge answer instead, and that answer is what
  /// gets remembered (frozen contract A-§2).
  ///
  /// The whole [ProbeResult] is returned, not just the rung, because the same
  /// single walk produced the orientation and this is the caller's one chance
  /// to keep it -- there is no second probe to ask later (invariant I6). The
  /// scheduler itself stores only cost: orientation is not a scheduling input,
  /// and parking it here would make this class the accidental owner of decode
  /// state it never reads.
  ///
  /// A memoized item short-circuits WITHOUT a walk, so its `exifOrientation`
  /// comes back null; the caller must keep the value it was handed the first
  /// time rather than expecting every call to restate it.
  Future<ProbeResult> classify(
    String id,
    String path, {
    required int longEdge,
  }) async {
    final known = _cost[id];
    if (known != null) return (cost: known, exifOrientation: null);
    // The canonical entry point, never the `probe()` projection: production
    // code must not depend on a cost-only view of a walk that also produced
    // the orientation this pipeline needs.
    final probed = await PhotoSource.probeSource(path, longEdge: longEdge);
    observe(id, probed.cost);
    return probed;
  }

  /// Whether a source for [id] may be STARTED right now, [distance] items away
  /// from the selection.
  ///
  /// An unmeasured item is allowed: the bridge answer is how its cost gets
  /// determined at all, and that call is the one the old code already made for
  /// every item in the window. What the caller must NOT do is let an
  /// unmeasured item perform an expensive decode -- see `allowsExpensiveWork`.
  bool allowsStartup(String id, {required int distance}) {
    return _cost[id] != SourceCost.expensive ||
        distance <= kExpensiveStartupRadius;
  }

  /// Whether an expensive decode may actually run for an item [distance] away.
  ///
  /// Deliberately independent of the memo: it gates the WORK, not the item, so
  /// an item whose cost is still unknown cannot smuggle a 400ms FFI decode
  /// into the immediate (undebounced) pass.
  bool allowsExpensiveWork({required int distance}) =>
      distance <= kExpensiveStartupRadius;

  void reset() => _cost.clear();
}
