import 'photo_source.dart';

export 'photo_source.dart' show ProbeResult, SourceCost;

/// How far from the selected item a FULL-SIZE (tier-2) decode is precached.
///
/// Retention is a wider thing again (`-3..+5`): this radius decides only which
/// slots are decoded at FULL size, not which are kept -- and, since the
/// 2026-08-26 serial-lane ruling, it decides nothing at all about which slots
/// may START an expensive decode. Every slot of the retention window may;
/// expensive ones simply queue on `SerialDecodeLane` instead of running in
/// parallel.
const int kTierTwoRadius = 2;

/// Decides WHICH LANE a source runs on. The only layer that knows about cost
/// (design §3.3).
///
/// Two rungs, keyed on MEASURED CONTENT:
///
/// | rung        | window                            | concurrency |
/// |-------------|-----------------------------------|-------------|
/// | `cheap`     | the whole -3..+5 retention window | parallel    |
/// | `expensive` | the whole -3..+5 retention window | serial      |
///
/// This is not the old type branch under a new name. The old rule picked the
/// rung from the file extension and was wrong 13 times in 14; measuring the
/// content moves those 13 onto the cheap rung and shrinks `expensive` from
/// "every DNG" to "files with no usable embedded JPEG at all".
///
/// **Cost is not a window.** User ruling 2026-08-26 (AD-018 overturned, see
/// `memory.md`): an expensive item is eligible everywhere a cheap one is, at
/// the same distances, behind the same retention rule. The measured cost picks
/// the LANE and nothing else.
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
    // The canonical entry point: production code must not depend on a
    // cost-only view of a walk that also produced the orientation this
    // pipeline needs (`PhotoSource.probe()` no longer exists -- removed
    // as the last of its callers were the frozen tests, re-anchored to
    // call `probeSource` directly instead).
    final probed = await PhotoSource.probeSource(path, longEdge: longEdge);
    observe(id, probed.cost);
    return probed;
  }

  void reset() => _cost.clear();
}
