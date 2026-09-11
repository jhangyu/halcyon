import 'prefetch_scheduler.dart';
import 'retention_policy.dart';

/// S3.1 (2026-09-11): the Flutter image-cache budget is derived from the
/// WORKING SET this app must hold, not from a percentage of machine memory.
///
/// What changed and why a future reader must not "fix" it back. Until
/// 2026-09-11 this file returned `physicalMemoryBytes ~/ 4`, clamped into a
/// rung-scaled ceiling of 768 / 800 / 896 MiB. That is a machine-RAM
/// percentage: on every machine at or above 3 GiB the quarter-of-RAM term
/// saturated the ceiling, so the shipped budget was simply "the largest number
/// this table allows", unrelated to how many images the pipeline actually
/// keeps alive. Spec S3.1 (game-console discipline) replaces that with the
/// arithmetic below, and states the reason the surplus is NOT claimed:
/// SURPLUS MEMORY IS DELIBERATELY LEFT TO THE OPERATING SYSTEM FILE CACHE,
/// which accelerates this app's own reads. An image cache sized past the
/// working set buys no cache hit that the working set did not already buy; it
/// only costs resident memory and evicts the operating system's copy of the
/// very files the preloader is about to read.
///
/// Machine memory survives ONLY as a downward safety ceiling
/// ([kMachineMemorySafetyCeilingDivisor]), never as the primary driver — the
/// same treatment design decision D1 gives the in-flight decode budget.
///
/// ATTRIBUTION EVIDENCE (AC-S3(a)).
/// `docs/logs/2026-09-11/memory-attribution-table.md` row "Flutter image cache
/// (all tiers)": steady-state mean 66,061,111 B, peak 102,087,560 B over a real
/// 48-file navigation-driven browse, against a configured ceiling of 768 MiB —
/// i.e. the shipped budget was roughly an order of magnitude above the observed
/// live bytes on that corpus. That same artifact records gate WP0.2-G1 as FAIL
/// (ledger-explained ratio 10.6 %, `memory-attribution-table.md:48-53`); the
/// user has ruled that Phase 4 proceeds regardless. The observed mean is
/// therefore used as a SANITY BOUND (the derived budget must not fall below
/// what a real browse was seen to hold), not as the derivation input: that
/// browse mixed corpora, while this pool must be sized against its WORST
/// corpus, the cheap preview-bearing one (see below).
///
/// DERIVATION (cheap, preview-bearing 24 MP corpus — the dear corpus for THIS
/// pool; see `docs/logs/2026-08-28/cache-sizing-rederivation.md` §2.1, whose
/// arithmetic these constants reproduce to the byte):
///
///   requirement = fullResolutionBandSlotCount
///                   * (fullResolutionImageByteCost + windowResolutionImageByteCost)
///               + windowResolutionOnlySlotCount * windowResolutionImageByteCost
///               + sidebarThumbnailPoolByteCost
///   budget      = roundUpToWholeMebibytes(requirement * safetyFactor)
///
/// For a preview-bearing item the tier-1 and tier-2 entries are DIFFERENT cache
/// keys that coexist, which is why every slot of the full-resolution band is
/// charged both costs.
///
/// This budget is NOT interchangeable with `kPayloadByteBudget`
/// (`photo_payload_cache.dart:43`): that one is sized against the OPPOSITE
/// (expensive, no-preview RAW) corpus, and neither can sanity-check the other.
/// `kPayloadByteBudget` and the per-rung payload budgets
/// (`retention_policy.dart:99-116`) are already working-set derived — slot count
/// times a measured per-item cost times a headroom factor — and machine memory
/// only selects WHICH RUNG applies, so S3.1 leaves their values untouched.

/// Full-resolution (tier-2) pixel cost of one item of the cheap 24 MP corpus:
/// 6000 x 4000 x 4 B RGBA = 91.55 MiB.
///
/// Evidence: `docs/logs/2026-08-23/cache-sizing-estimate.md` §A.4, re-read in
/// `docs/logs/2026-08-28/cache-sizing-rederivation.md` §1.
const int kFullResolutionImageByteCost = 96000000;

/// Window-resolution (tier-1) pixel cost of one item: 18.54 MiB at the
/// reference 1440x900 logical window and device pixel ratio 2.0.
///
/// Evidence: same two documents as [kFullResolutionImageByteCost].
const int kWindowResolutionImageByteCost = 19440000;

/// What the sidebar thumbnail pool holds, across both pools: 1.6 MiB.
///
/// Evidence: `docs/logs/2026-08-23/cache-sizing-estimate.md` §A.4.
const int kSidebarThumbnailPoolByteCost = 1677722;

/// How many slots hold a FULL-RESOLUTION decoded image at once.
///
/// DERIVED from the band the tier-2 scheduler actually precaches
/// (`prefetch_scheduler.dart`'s [kFullResolutionBandRadius]) rather than
/// restated here, so a change to the band cannot leave this pool sized for a
/// window the app no longer holds. That coupling is the point: the budget is
/// the band's consequence.
const int kFullResolutionBandSlotCount = kFullResolutionBandRadius * 2 + 1;

/// Headroom above the computed working-set row: 15 %.
///
/// Not decoration and not trimmable to make a number look smaller. Flutter's
/// image cache is byte-LRU, so any transient overshoot (one in-flight
/// full-resolution decode is 91.55 MiB on its own, a band slide, a display at
/// device pixel ratio above 2.0) evicts the least-recently-used entry — which,
/// browsing forward, is exactly the `-1` tier-2 entry the back-navigation
/// no-re-decode guarantee depends on. 15 % restores the headroom policy the
/// original fixed 768 MiB figure was chosen under
/// (`docs/logs/2026-08-28/cache-sizing-rederivation.md` §3).
const double kImageCacheSafetyFactor = 1.15;

/// Machine memory enters ONLY here, and only downward: the derived budget is
/// additionally capped at one quarter of total physical memory so a small
/// machine is never asked to hold a budget derived for a large working set.
/// On any machine whose quarter-of-memory exceeds the derived budget this term
/// does nothing at all, which is the intended common case.
const int kMachineMemorySafetyCeilingDivisor = 4;

/// Never go below this, even under the machine-memory safety ceiling: below
/// roughly this figure the M5 no-re-decode guarantee dies
/// (`docs/logs/2026-08-23/cache-sizing-estimate.md`).
const int kImageCacheFloorBytes = 256 << 20;

const int _bytesPerMebibyte = 1 << 20;

/// The pure working-set arithmetic, with every input named and injectable so a
/// test can pin the formula rather than re-assert a magic number.
///
/// [safetyFactor] multiplies the computed requirement; the product is rounded
/// UP to a whole mebibyte. [machineMemorySafetyCeilingBytes], when supplied, is
/// a DOWNWARD clamp only (see [kMachineMemorySafetyCeilingDivisor]) and never
/// raises the result; the result never falls below [kImageCacheFloorBytes].
int imageCacheBudgetBytesFromWorkingSet({
  required int fullResolutionBandSlotCount,
  required int windowResolutionOnlySlotCount,
  required int fullResolutionImageByteCost,
  required int windowResolutionImageByteCost,
  required int sidebarThumbnailPoolByteCost,
  required double safetyFactor,
  int? machineMemorySafetyCeilingBytes,
}) {
  final requirementBytes =
      fullResolutionBandSlotCount *
          (fullResolutionImageByteCost + windowResolutionImageByteCost) +
      windowResolutionOnlySlotCount * windowResolutionImageByteCost +
      sidebarThumbnailPoolByteCost;
  final withHeadroomBytes = (requirementBytes * safetyFactor).ceil();
  final roundedUpToWholeMebibytes =
      ((withHeadroomBytes + _bytesPerMebibyte - 1) ~/ _bytesPerMebibyte) *
      _bytesPerMebibyte;
  final afterSafetyCeiling = machineMemorySafetyCeilingBytes == null
      ? roundedUpToWholeMebibytes
      : (roundedUpToWholeMebibytes < machineMemorySafetyCeilingBytes
            ? roundedUpToWholeMebibytes
            : machineMemorySafetyCeilingBytes);
  return afterSafetyCeiling < kImageCacheFloorBytes
      ? kImageCacheFloorBytes
      : afterSafetyCeiling;
}

/// The app's image-cache budget for [retention], which is the only thing that
/// changes how many slots are held at once.
///
/// The retention window sets the tier-1 slot count (`before + after + 1`); the
/// first [kFullResolutionBandSlotCount] of those also hold a full-resolution
/// entry, so the remainder are window-resolution only. [physicalMemoryBytes]
/// is used solely as the downward safety ceiling described in
/// [kMachineMemorySafetyCeilingDivisor]; a null reading (every platform except
/// macOS today) simply means no ceiling applies.
int imageCacheBudgetBytes({
  RetentionPolicy retention = const RetentionPolicy.floor(),
  int? physicalMemoryBytes,
}) {
  final retentionSlotCount = retention.before + retention.after + 1;
  final windowResolutionOnlySlotCount =
      retentionSlotCount - kFullResolutionBandSlotCount;
  return imageCacheBudgetBytesFromWorkingSet(
    fullResolutionBandSlotCount: kFullResolutionBandSlotCount,
    windowResolutionOnlySlotCount: windowResolutionOnlySlotCount < 0
        ? 0
        : windowResolutionOnlySlotCount,
    fullResolutionImageByteCost: kFullResolutionImageByteCost,
    windowResolutionImageByteCost: kWindowResolutionImageByteCost,
    sidebarThumbnailPoolByteCost: kSidebarThumbnailPoolByteCost,
    safetyFactor: kImageCacheSafetyFactor,
    machineMemorySafetyCeilingBytes: physicalMemoryBytes == null
        ? null
        : physicalMemoryBytes ~/ kMachineMemorySafetyCeilingDivisor,
  );
}
