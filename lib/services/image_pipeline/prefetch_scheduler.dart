import 'photo_source.dart';

export 'photo_source.dart' show ProbeResult, SourceCost;

/// The FULL-RESOLUTION BAND: the slots around the selected item that hold a
/// decoded full-size image, `-kFullResolutionBandBefore..+kFullResolutionBandAfter`.
/// THE ONE SOURCE OF TRUTH for the band -- the tier-2 scheduler's id set, its
/// sweep range and the image-cache budget's slot count all derive from these
/// two constants.
///
/// Retention is a much wider thing (`-3..+5` on the floor rung, wider per rung
/// in `retention_policy.dart`): this band decides only which slots are decoded
/// at FULL size, not which are kept -- and, since the 2026-08-26 serial-lane
/// ruling, nothing about which slots may START an expensive decode.
///
/// HISTORY. WP4.2 had `-1..+3`; S3.2 narrowed it to a symmetric `+/-1`
/// (2026-09-11) while a viewport-resolution decode still covered first paint.
/// USER RULING 2026-10-04 (memory.md AD-072): the viewport-resolution decode is
/// removed -- full resolution is the only decoded form -- and the memory it
/// saved buys one more forward slot, so the band is `-1..+2` (4 slots).
const int kFullResolutionBandBefore = 1;

/// See [kFullResolutionBandBefore]. Forward-biased because browsing is
/// overwhelmingly forwards.
const int kFullResolutionBandAfter = 2;

/// The band the payload cache's EVICTION RANKING is computed against
/// (`ImagePreloadController._evictionOrderIndices`): ids beyond
/// `-kEvictionBandBefore..+kEvictionBandAfter` sort last and are evicted first.
///
/// Deliberately a SEPARATE pair of constants from
/// [kFullResolutionBandBefore]/[kFullResolutionBandAfter], frozen at the pre-WP4.2 `-1..+3` values.
/// Eviction ordering is retention policy, which S3.2 places out of scope, so
/// narrowing the resolution band must not move it. Two names, because they are
/// two questions: "what form is this item held in" and "who loses their payload
/// first when the budget bites".
const int kEvictionBandBefore = 1;

/// See [kEvictionBandBefore]. The larger of the two because browsing is
/// overwhelmingly forwards, so behind-side ids lose the budget first.
const int kEvictionBandAfter = 3;

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
  /// id -> (measured cost, the long edge it was measured AT). Written at most
  /// once per item PER LONG EDGE and cleared only by [reset] (i.e. a folder
  /// reload), so a file is asked about once per folder rather than once per
  /// navigation.
  ///
  /// This is the successor to the old per-item raw-decode map's exactly-once
  /// guarantee (invariant I6), and it is strictly stronger: the old map only existed for
  /// items the native side flagged, so a permanently failing THUMBNAIL was
  /// re-asked on every sweep forever (invariant I8's defect). One memo now
  /// covers raw items, non-raw failures and thumbnails alike.
  ///
  /// WHY THE LONG EDGE IS PART OF THE KEY (F5/AC7, 2026-09-03). The rung is not
  /// a property of the file: it is the answer to "is this file's embedded
  /// preview big enough for THIS viewport" (AD-033). Keyed by id alone, the
  /// whole first window was answered against `kDefaultPreviewLongEdge` (2800) —
  /// the bootstrap placeholder `ImagePreloadController._longEdge` returns until
  /// the viewport's LayoutBuilder calls `updateTargetSize`, which happens AFTER
  /// the first preload pass — and that placeholder verdict was never revisited,
  /// not when the real viewport reported and not on a resize. On a display
  /// wider than 2800 that left previews between 2800 and the real viewport
  /// permanently `cheap` and displayed upscaled: exactly the outcome AD-033
  /// exists to prevent.
  ///
  /// The economy is preserved, not traded away: for a STABLE viewport this is
  /// still one walk per file per folder. Extra walks are bounded by the number
  /// of distinct long edges seen, i.e. by resize events — navigation does not
  /// change the long edge, so this is not a probe-per-navigation regression.
  final Map<String, ({SourceCost cost, int longEdge})> _cost = {};

  /// Records [cost] for [id] as measured at [longEdge], first writer wins
  /// WITHIN a long edge.
  ///
  /// First-writer-wins matters: the content probe and the bridge answer can
  /// both speak for the same item, and letting a later observation overwrite
  /// an earlier one would make the rung -- and therefore the number of native
  /// calls -- depend on navigation history. That arbitration is unchanged; it
  /// simply no longer spans two different questions. An observation made at a
  /// DIFFERENT long edge replaces the stored one, because it answers the
  /// question the pipeline is asking now and the stored one does not.
  void observe(String id, SourceCost? cost, {required int longEdge}) {
    if (cost == null) return;
    final known = _cost[id];
    if (known != null && known.longEdge == longEdge) return;
    _cost[id] = (cost: cost, longEdge: longEdge);
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
    // F5/AC7: the memo may only answer the question it was asked. A verdict
    // measured against a different long edge (the 2800 bootstrap placeholder,
    // or a pre-resize viewport) says nothing about this one, so it is
    // re-measured instead of re-served.
    final known = _cost[id];
    if (known != null && known.longEdge == longEdge) {
      return (cost: known.cost, exifOrientation: null);
    }
    // The canonical entry point: production code must not depend on a
    // cost-only view of a walk that also produced the orientation this
    // pipeline needs (`PhotoSource.probe()` no longer exists -- removed
    // as the last of its callers were the frozen tests, re-anchored to
    // call `probeSource` directly instead).
    final probed = await PhotoSource.probeSource(path, longEdge: longEdge);
    observe(id, probed.cost, longEdge: longEdge);
    return probed;
  }

  void reset() => _cost.clear();
}
