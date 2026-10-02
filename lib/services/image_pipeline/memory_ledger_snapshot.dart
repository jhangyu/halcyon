/// One coherent reading of every byte ledger `ImagePreloadController` owns,
/// for the S3.0 memory-attribution capture (WP0.2).
///
/// A value object rather than loose getters so the capture cannot accidentally
/// mix readings taken at different instants, and so the field set is a stable
/// schema its consumer can parse against.
///
/// THE TRANSIENT TOTAL IS TWO NUMBERS, NOT ONE. Since S1.3 a frame past the
/// decode->encode stage boundary is charged to [encodePublishTailBytes], not to
/// [decodeInflightBytes]; anything that reports a single "in flight" figure
/// silently under-counts the tail, which at wide lane settings is the larger of
/// the two.
class MemoryLedgerSnapshot {
  const MemoryLedgerSnapshot({
    required this.decodeInflightBytes,
    required this.encodePublishTailBytes,
    required this.retainedPayloadBytes,
    required this.retainedPayloadByteBudget,
    required this.decodeInflightByteBudget,
    required this.payloadCachePixelEntryCount,
    required this.payloadCachePixelByteTotal,
    required this.payloadCacheEncodedByteTotal,
  });

  /// Bytes charged to decodes currently in flight (pre-decode nominal estimate
  /// until the decode returns, real size afterwards).
  final int decodeInflightBytes;

  /// Bytes charged to frames that have left the decode lane and are still alive
  /// through encode, publication pacing and the idle-publish wait. Always the
  /// REAL frame size, never the nominal estimate.
  final int encodePublishTailBytes;

  /// LIVE retained payload bytes -- what the retention cache is actually
  /// holding right now. Not to be confused with
  /// [retainedPayloadByteBudget], which is only its ceiling.
  final int retainedPayloadBytes;

  /// The retention tier's payload ceiling.
  final int retainedPayloadByteBudget;

  /// The decode gate's ceiling, derived from the decode lane width.
  final int decodeInflightByteBudget;

  /// How many retained entries are still in the PIXEL form, and their cost.
  ///
  /// AC-1 of spec v2 is a claim about this number being zero in steady state.
  /// It is part of the schema (not a loose getter) because the capture harness
  /// parses the schema, and a per-kind number read at a different instant from
  /// [retainedPayloadBytes] would describe a state the app was never in.
  final int payloadCachePixelEntryCount;
  final int payloadCachePixelByteTotal;

  /// Retained bytes in the ENCODED form. Its sum with
  /// [payloadCachePixelByteTotal] is [retainedPayloadBytes]; a fall in the
  /// total accompanied by a fall in BOTH terms is items disappearing, not the
  /// pixel->encoded shift this round expects (invariant I9).
  final int payloadCacheEncodedByteTotal;

  @override
  String toString() =>
      'MemoryLedgerSnapshot(decodeInflightBytes: $decodeInflightBytes, '
      'encodePublishTailBytes: $encodePublishTailBytes, '
      'retainedPayloadBytes: $retainedPayloadBytes, '
      'retainedPayloadByteBudget: $retainedPayloadByteBudget, '
      'decodeInflightByteBudget: $decodeInflightByteBudget, '
      'payloadCachePixelEntryCount: $payloadCachePixelEntryCount, '
      'payloadCachePixelByteTotal: $payloadCachePixelByteTotal, '
      'payloadCacheEncodedByteTotal: $payloadCacheEncodedByteTotal)';
}
