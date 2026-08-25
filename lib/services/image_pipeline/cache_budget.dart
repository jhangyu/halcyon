/// M6 F-25 / P5.1: image-cache budget derived from physical memory, behind
/// an injectable seam.
///
/// Honest constraint: `dart:io` (Dart 3.9) exposes no platform-neutral
/// total-physical-memory API — `ProcessInfo` only reports this process's RSS,
/// not device total memory — and `Platform.isX` branches are forbidden
/// (C-3). So this ships the pure derivation function with the current fixed
/// budget as the no-source default; a future platform-neutral memory probe
/// plugs in via [physicalMemoryBytes] without touching this function or
/// violating C-3.
///
/// With a memory reading supplied, the budget is a quarter of physical
/// memory, clamped to [256 MiB, 768 MiB]: the floor is where the M5
/// no-re-decode guarantee dies (see `cache-sizing-estimate.md`), the ceiling
/// is the desktop sizing this app currently ships (§A.4/§A.6 of the same
/// doc) and must not be exceeded without re-deriving that estimate.
///
/// 768 MiB = 805,306,368 B. Sized against the CHEAP (preview-bearing) corpus,
/// NOT the expensive one: a preview-bearing item decodes its tier-2 entry at
/// FULL native size (24MP -> 91.55 MiB here) and holds a SECOND, separate
/// tier-1 entry, while a no-preview RAW is already window-sized and shares ONE
/// entry across both tiers. The dear entries therefore come from the cheap rung.
/// Requirement is 626.22 MiB (5 full-size + their coexisting tier-1 entries + 4
/// outer tier-1 + sidebar); 640 MiB would leave only 2.2% headroom and evict the
/// very entry the no-re-decode guarantee just promised. Derivation:
/// docs/logs/2026-08-23/cache-sizing-estimate.md §A.4/§A.6. This used to be
/// duplicated as a decorative `imageCacheMaxBytes` const in main.dart that
/// nothing read.
///
/// This is NOT interchangeable with `kPayloadByteBudget`: the two are sized
/// against different corpora and neither can sanity-check the other.
const int kImageCacheCeilingBytes = 768 << 20;

int imageCacheBudgetBytes({int? physicalMemoryBytes}) {
  const floor = 256 << 20;
  const ceiling = kImageCacheCeilingBytes;
  if (physicalMemoryBytes == null) return ceiling;
  return (physicalMemoryBytes ~/ 4).clamp(floor, ceiling);
}
