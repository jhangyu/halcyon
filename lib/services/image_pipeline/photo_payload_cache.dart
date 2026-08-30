import 'dart:collection';

import 'photo_payload.dart';

/// Items retained BEFORE the selected one.
const int kRetentionBefore = 3;

/// Items retained AFTER the selected one. Asymmetric because browsing is
/// overwhelmingly forwards.
const int kRetentionAfter = 5;

/// Ceiling on the total resident payload cost.
///
/// ponytail: one global number, not a per-kind budget. Make it configurable
/// per-cache (the constructor argument) before making it adaptive.
///
/// 256 MiB = 268,435,456 B. Sized against the EXPENSIVE (no-preview RAW)
/// corpus, which is the opposite corpus from the one that sizes
/// `imageCacheBudgetBytes`: a RAW payload retains window-resolution RGBA (22.4 MiB
/// measured per item, so a full -3..+5 window is 201.59 MiB), while a
/// preview-bearing payload retains compressed JPEG bytes (~2.6 MiB, 23.22 MiB
/// for the window). 224 MiB used to carry ~11% headroom over the 201.59 MiB row;
/// raised to 256 MiB (2026-08-30, AD-042/AD-043) after a measured fill report
/// (docs/logs/2026-08-30/shared-payload-fill-report.md) showed the shipped
/// embedded-JPEG-normalised path needs 316.61 MiB for a top-60 set, exceeding
/// this floor even after the raise -- see
/// docs/logs/2026-08-30/cache-rung-raise-rederivation.md for the accepted
/// residual gap, absorbed by existing eviction-on-overflow (no proactive
/// shrink eviction, ruling E-M5).
///
/// AMENDMENT (Phase 13, AD-040): the 22.4 MiB figure above now describes only
/// the encode-failure fallback path. A re-encoded RAW payload retains one
/// full-resolution JPEG; this budget is deliberately NOT re-derived in that phase.
///
/// Below ~202 MiB an in-window RAW payload is dropped and re-entering that slot
/// costs a full sequential RAW decode (~8.5 s measured) instead of a cache hit
/// -- which is the one cost this retention design exists to avoid. Unused
/// budget is not free either: it is headroom the cache will fill before
/// evicting anything, which is why this sits just above the row it must hold
/// rather than at a round larger number. Derivation:
/// docs/logs/2026-08-23/cache-sizing-estimate.md §A.5/§A.6;
/// re-derived docs/logs/2026-08-30/cache-rung-raise-rederivation.md.
const int kPayloadByteBudget = 256 * 1024 * 1024;

/// The one place the pipeline decides WHAT TO KEEP.
///
/// User decision D4: retention is 100% identical across file types -- one
/// `-3..+5` window, one byte budget, one eviction rule. This class therefore
/// cannot tell what kind of payload it is holding; it reads
/// [SourcePayload.byteCost] and nothing else. That is mechanically checked --
/// neither payload subclass may be NAMED anywhere in this file, not even in a
/// comment (design §3.2's grep). They are declared in `photo_payload.dart`
/// precisely so the property is structural rather than a matter of care.
///
/// It also **disposes nothing**. Every payload is a plain `Uint8List`, so
/// eviction is dropping a reference. The ~50MB `ui.Image` ownership contract
/// that used to live in the preload controller (evict-before-dispose,
/// in-flight sets, a late decode killing itself) is not reproduced here
/// because there is no longer anything whose lifetime has to be managed by
/// hand (design §4, I5 deliberately dissolved).
class PhotoPayloadCache {
  PhotoPayloadCache({int byteBudget = kPayloadByteBudget})
    : _byteBudget = byteBudget < 1 ? 1 : byteBudget;

  int _byteBudget;

  /// The hard cap on retained payload bytes. Read-only; see [setByteBudget].
  int get byteBudget => _byteBudget;

  /// Re-sizes the budget and sweeps IMMEDIATELY.
  ///
  /// The sweep is the point: a user stepping the retention tier down expects
  /// the memory back now, not at the next navigation. Shrinking without
  /// sweeping would hold up to the OLD budget indefinitely on a folder the
  /// user has stopped scrolling.
  ///
  /// The [_entries] guard is required, not defensive: [_enforceBudget] reads
  /// `_entries.keys.last` unconditionally, which throws on an empty map. That
  /// path was previously unreachable because only [put] called it.
  void setByteBudget(int bytes) {
    _byteBudget = bytes < 1 ? 1 : bytes;
    if (_entries.isNotEmpty) _enforceBudget();
  }

  // Distance-ordered eviction (user ruling 2026-08-27, replacing the FIFO
  // rule that preceded the serial-lane unification). The controller calls
  // [setEvictionPriority] with ids near-to-far from the current selection on
  // every navigation event; [_enforceBudget] evicts from the FAR end of that
  // order, so the selected item is structurally last in line.
  //
  // Ids not in the priority list (possible during a brief window between `put`
  // and the next `setEvictionPriority` call) are evicted first, oldest-first
  // among themselves -- the safe fallback, since an unknown id is definitionally
  // not near the selection.
  final LinkedHashMap<String, SourcePayload> _entries =
      LinkedHashMap<String, SourcePayload>();

  // Near-to-far priority order, set by the controller's preloadImages pass.
  // Index 0 = nearest (selected item), last = farthest. Empty until the first
  // call to [setEvictionPriority].
  List<String> _evictionPriority = [];

  /// Sets the eviction priority order: [idsNearToFar] lists retained ids from
  /// nearest (index 0 = selected item) to farthest. [_enforceBudget] evicts
  /// from the far end first, so the selected item is the last victim.
  ///
  /// Called by the controller's preloadImages pass, which already computes
  /// the near-to-far walk order.
  void setEvictionPriority(List<String> idsNearToFar) {
    _evictionPriority = idsNearToFar;
  }

  /// Read, for bookkeeping and assertions. Does not affect eviction order.
  SourcePayload? peek(String? id) => id == null ? null : _entries[id];

  bool contains(String id) => _entries.containsKey(id);

  int get totalByteCost {
    var sum = 0;
    for (final payload in _entries.values) {
      sum += payload.byteCost;
    }
    return sum;
  }

  int get length => _entries.length;

  Iterable<String> get ids => _entries.keys;

  /// Retains [payload] for [id] and enforces the byte budget.
  ///
  /// The just-written entry is the most recently used, so it is the last thing
  /// that can be evicted: a single payload larger than the whole budget is
  /// kept rather than being written and immediately dropped, which would show
  /// the user a spinner that can never resolve.
  void put(String id, SourcePayload payload) {
    _entries.remove(id);
    _entries[id] = payload;
    _enforceBudget();
  }

  /// Drops every entry whose id is not in [ids] -- the `-3..+5` sweep.
  ///
  /// Returns the ids actually dropped, so the caller can retire whatever
  /// bookkeeping it keeps alongside (ImageCache keys, readiness flags).
  List<String> retainOnly(Set<String> ids) {
    final dropped = _entries.keys.where((id) => !ids.contains(id)).toList();
    for (final id in dropped) {
      _entries.remove(id);
    }
    return dropped;
  }

  List<String> clear() {
    final dropped = _entries.keys.toList();
    _entries.clear();
    return dropped;
  }

  void _enforceBudget() {
    var total = totalByteCost;
    // The just-written entry is the last key in `_entries` (LinkedHashMap
    // insertion order). It must never be evicted in the same `put` call —
    // writing a payload and immediately dropping it strands the user on a
    // spinner that can never resolve.
    final justWritten = _entries.keys.last;
    while (total > byteBudget && _entries.length > 1) {
      final victim = _pickVictim(exclude: justWritten);
      final evicted = _entries.remove(victim)!;
      total -= evicted.byteCost;
    }
  }

  /// Picks the eviction victim: the retained id FARTHEST from the current
  /// selection according to [_evictionPriority]. Ids not in the priority list
  /// are evicted first (oldest first among them). Among ids in the list, the
  /// one at the highest index (farthest) goes first. [exclude] is never
  /// returned (the just-written entry).
  String _pickVictim({required String exclude}) {
    if (_evictionPriority.isEmpty) {
      // No priority set yet: fall back to oldest entry (FIFO), skipping
      // the excluded id.
      for (final id in _entries.keys) {
        if (id != exclude) return id;
      }
      return _entries.keys.first; // unreachable when length > 1
    }
    String? bestUnknown; // oldest entry not in priority list
    String? farthestKnown; // entry with highest priority index
    int farthestIndex = -1;
    for (final id in _entries.keys) {
      if (id == exclude) continue;
      final idx = _evictionPriority.indexOf(id);
      if (idx == -1) {
        // Not in priority list: evict this before any known id.
        // Take the first one found (oldest, since _entries is insertion-ordered).
        bestUnknown ??= id;
      } else if (idx > farthestIndex) {
        farthestIndex = idx;
        farthestKnown = id;
      }
    }
    return bestUnknown ?? farthestKnown ?? _entries.keys.first;
  }
}

/// The ids inside the retention window centred on [index].
///
/// The one definition of the window, so "cache retention is the same for every
/// file type" is not something three call sites have to agree about. The
/// tier-2 decode window uses a different (symmetric) radius from the tier-1
/// retention window, which is why [before] and [after] are parameters rather
/// than always the constants.
Set<String> retentionWindowIds<T>(
  List<T> items,
  int index,
  String Function(T item) idOf, {
  int before = kRetentionBefore,
  int after = kRetentionAfter,
}) {
  if (items.isEmpty || index < 0) return const <String>{};
  final start = (index - before).clamp(0, items.length - 1);
  final end = (index + after).clamp(0, items.length - 1);
  return {for (var i = start; i <= end; i++) idOf(items[i])};
}
