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
int imageCacheBudgetBytes({int? physicalMemoryBytes}) {
  const floor = 256 << 20;
  const ceiling = 768 << 20;
  if (physicalMemoryBytes == null) return ceiling;
  return (physicalMemoryBytes ~/ 4).clamp(floor, ceiling);
}
