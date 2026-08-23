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
/// 224 MiB = 234,881,024 B. Sized against the EXPENSIVE (no-preview RAW)
/// corpus, which is the opposite corpus from the one that sizes
/// `imageCacheMaxBytes`: a RAW payload retains window-resolution RGBA (22.4 MiB
/// measured per item, so a full -3..+5 window is 201.59 MiB), while a
/// preview-bearing payload retains compressed JPEG bytes (~2.6 MiB, 23.22 MiB
/// for the window). 224 MiB carries ~11% headroom over the 201.59 MiB row.
///
/// Below ~202 MiB an in-window RAW payload is dropped and re-entering that slot
/// costs a full sequential RAW decode (~8.5 s measured) instead of a cache hit
/// -- which is the one cost this retention design exists to avoid. Unused
/// budget is not free either: it is headroom the LRU will fill before evicting
/// anything, which is why this sits just above the row it must hold rather than
/// at a round larger number. Derivation:
/// docs/logs/2026-08-23/cache-sizing-estimate.md §A.5/§A.6.
const int kPayloadByteBudget = 224 * 1024 * 1024;

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
  PhotoPayloadCache({this.byteBudget = kPayloadByteBudget});

  final int byteBudget;

  // Insertion-ordered; re-inserted on every read/write, so iteration order is
  // least-recently-used first.
  final LinkedHashMap<String, SourcePayload> _entries =
      LinkedHashMap<String, SourcePayload>();

  /// The retained payload for [id], or null. Counts as a use for LRU purposes.
  SourcePayload? operator [](String? id) {
    if (id == null) return null;
    final payload = _entries.remove(id);
    if (payload == null) return null;
    _entries[id] = payload;
    return payload;
  }

  /// Read WITHOUT touching LRU order, for bookkeeping and assertions.
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
    while (total > byteBudget && _entries.length > 1) {
      final lruId = _entries.keys.first;
      final evicted = _entries.remove(lruId)!;
      total -= evicted.byteCost;
    }
  }
}

/// The ids inside the retention window centred on [index].
///
/// The one definition of the window, so "cache retention is the same for every
/// file type" is not something two call sites have to agree about.
Set<String> retentionWindowIds<T>(
  List<T> items,
  int index,
  String Function(T item) idOf,
) {
  if (items.isEmpty || index < 0) return const <String>{};
  final start = (index - kRetentionBefore).clamp(0, items.length - 1);
  final end = (index + kRetentionAfter).clamp(0, items.length - 1);
  return {for (var i = start; i <= end; i++) idOf(items[i])};
}
