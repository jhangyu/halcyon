import 'package:flutter/foundation.dart';

import '../../perf/perf_log.dart';
import 'jpeg_encoder.dart';
import 'photo_payload.dart';

/// The seam through which decoded RAW pixels become an encoded bitstream.
///
/// Injected rather than called directly so the pipeline can be unit-tested
/// without spawning an isolate, mirroring the `DngFullDecoder` seam. The
/// production binding is `encodeJpegFromRgba` (`jpeg_encoder.dart`).
///
/// Erratum E-WP3b (gc-remediation R2, 2026-09-06): the plan's original design
/// widened this typedef with two extra OPTIONAL named parameters
/// (`nativeAddress`, `keepAlive`), on the claim that every existing test
/// closure would "keep compiling unchanged". That claim is false for Dart's
/// function-type subtyping: a function type that declares an optional named
/// parameter still requires an assigned closure to declare that same
/// parameter (proof: `Enc e = fakeOld;` where `fakeOld` lacks the extra param
/// is a compile error, not a silent no-op) -- this typedef is left
/// BYTE-IDENTICAL, and the pointer path is a wholly separate, additional
/// encoder typedef instead (see [PointerPayloadEncoder]).
typedef PayloadEncoder =
    Future<Uint8List> Function(
      Uint8List rgba, {
      required int width,
      required int height,
      required int quality,
    });

/// The pointer-based sibling of [PayloadEncoder] (WP3, gc-remediation R2):
/// encodes an RGBA8 frame that already lives in native memory, without the
/// Dart-heap copy [PayloadEncoder] requires. Mirrors ceyx's
/// `encodeJpegFromNativeRgba` (`../ceyx/plugin/lib/src/encode_service.dart`,
/// landed eec995b).
///
/// [keepAlive] must be kept reachable by the caller for the duration of the
/// returned future -- typically the `DecodedRgba`/`DngImage` handle owning
/// the native buffer -- so the VM's `NativeFinalizer` cannot free the buffer
/// mid-encode. `reencodePayload` itself only forwards this value; it does not
/// retain it beyond the awaited call.
typedef PointerPayloadEncoder =
    Future<Uint8List> Function({
      required int nativeAddress,
      required int width,
      required int height,
      required int quality,
      Object? keepAlive,
    });

/// q70 -- what EVERY retained payload is encoded at, RAW and JPG alike.
///
/// USER RULING 2026-08-30 (contract D5), superseding the q80 default recorded
/// below: under the shared-payload design one q70 bitstream serves the main
/// preview, the tier-1 downscale AND the sidebar tile, and the sidebar tile is
/// a 200px resample where q70 vs q80 is invisible. The bytes are display-only
/// (export re-reads the original file, `photo_export_service.dart`), so the
/// extra q80 bytes buy detail nothing writes back to disk -- and they are
/// bytes the payload budget has to hold for every item a scroll touches.
///
/// Superseded history, kept because the reasoning still applies one step down:
/// q90 -> q80 (2026-08-30, same ruling family) for the same display-only
/// argument.
///
/// The SAME number as `sidebar_thumbnail_codec.dart`'s tile quality, by
/// construction rather than by coincidence: both are display-only encodes and
/// both read [kDisplayJpegQuality] (`jpeg_encoder.dart`), the single source of
/// truth introduced on 2026-08-30. The historical note above records why the
/// value walked 90 -> 80 -> 70; the value itself now lives in one place.
const int kReencodeJpegQuality = kDisplayJpegQuality;

/// How many times re-encoding degraded to the retained-pixels fallback.
///
/// Observability, not policy: a re-encode that silently failed on every item
/// would look exactly like the pre-Phase-13 behaviour, and the whole phase
/// would be a no-op nobody noticed.
@visibleForTesting
int reencodeFallbacks = 0;

/// How many full-size JPEGs were produced by the DEFERRED path rather than
/// inline (compressed-residency v2 Task 3). Observability twin of
/// [reencodeFallbacks]: with both at zero the round is a no-op, and with
/// `reencodeFallbacks` high and this at zero the deferred path is wired but
/// never lands -- two failures that look identical in a retention capture.
///
/// Deliberately NOT `@visibleForTesting`, unlike its twin: the increment site
/// is `deferred_full_size_encoder.dart`, another `lib/` file, which the
/// annotation forbids (the twin is only ever written inside THIS file). Same
/// convention `TierTwoScheduler.debugCatchUpEnqueueCount` records at
/// `tier_two_scheduler.dart:145-149`.
int deferredFullSizeEncodes = 0;

@visibleForTesting
void resetReencodeCounters() {
  reencodeFallbacks = 0;
  deferredFullSizeEncodes = 0;
}

/// Turns the FULL-RESOLUTION pixels produced by ONE RAW decode into the single
/// bitstream this item will retain -- once, in final form.
///
/// One buffer, by user ruling (2026-08-30): the retained `EncodedPayload.bytes`
/// IS the full-resolution JPEG, exactly as a JPG file's bytes are, so both
/// tiers read one buffer and a RAW item stops being a special cache citizen.
///
/// The result is written to the payload cache unchanged and NEVER swapped
/// afterwards: payload object identity is the tier-1 ImageCache key and the
/// tier-2 registry's readiness anchor, so a later swap orphans both.
///
/// Every failure degrades to [fallback] -- window-resolution pixels for the
/// RAW decode path, or the original encoded bytes for `normalizeEncodedPayload`
/// (Task 2), depending on the caller -- so the item renders exactly as it did
/// before this phase existed. Failure is never an error and never a permanent
/// miss.
///
/// This function's guards are not the only refusal in the pipeline: when the
/// caller is `normalizeEncodedPayload` (`payload_normalizer.dart`, amendment
/// E-M1), that caller applies one more, independent check AFTER this function
/// returns -- discarding a smaller-than-expected win by keeping the original
/// bytes if the re-encoded result is not actually smaller than the input, on
/// top of its own small-input passthrough before this function is ever
/// called. See `normalizeEncodedPayload`'s dartdoc for both.
Future<SourcePayload> reencodePayload({
  required PayloadEncoder encoder,
  /// A THUNK, not a value (WP1, gc-remediation 2026-09-06): building the
  /// fallback is what allocates the ~21MB window-resolution buffer, and every
  /// exit below that does not return it never needed it. Invoked AT MOST ONCE,
  /// on the four failure exits only -- the success path never calls it.
  required Future<SourcePayload> Function() fallback,
  required ({Uint8List rgba, int width, int height})? fullRes,
  int quality = kReencodeJpegQuality,
  /// WP3/E-WP3b (gc-remediation R2). Both default to the "not available"
  /// state so every EXISTING caller (`photo_source.dart`,
  /// `payload_normalizer.dart`, and every test in this suite) is byte-for-byte
  /// unchanged: [pointerEncoder] null or [nativeAddress] == 0 means this
  /// function behaves exactly as it did before WP3, using [encoder] on
  /// [fullRes].rgba. Only a caller that supplies BOTH a non-null
  /// [pointerEncoder] and a non-zero [nativeAddress] takes the pointer path.
  PointerPayloadEncoder? pointerEncoder,
  int nativeAddress = 0,
  Object? keepAlive,
}) async {
  if (fullRes == null) {
    // Nothing to encode. Deliberately NOT falling back to encoding the
    // window-resolution pixels: those would land in the full-size tier and
    // silently show a low-resolution frame at 100% zoom.
    reencodeFallbacks++;
    return await fallback();
  }

  // The native encoder trusts width*height to bound its scanline reads
  // (encode_ffi_api.cpp cannot itself validate the buffer's real length --
  // it only has the pointer and the claimed dimensions). A short buffer
  // would be a heap OOB read in release. Every other consumer of a decoded
  // RGBA record either asserts this invariant (debug-only) or bails on
  // mismatch (tier_two_scheduler.dart); this is the only unguarded one.
  if (fullRes.rgba.lengthInBytes != fullRes.width * fullRes.height * 4) {
    reencodeFallbacks++;
    return await fallback();
  }

  Uint8List jpeg;
  // P0 (docs/logs/2026-09-05/pool-round-contract.md AC7 /
  // pipeline-architecture-v2.md §5-P0): submit/end split so the worker's
  // native encode time is separable in the log from the publish step that
  // follows in the caller. No photo id is threaded this far down the call
  // chain (`reencodePayload` only receives the raw buffers), so
  // `identityHashCode(fullRes.rgba)` is used as the correlation id -- stable
  // for the lifetime of this one call, unique enough to pair submit with
  // end, and free to compute (an int read, not an allocation).
  final reencodeId = PerfLog.enabled ? identityHashCode(fullRes.rgba) : 0;
  final usePointer = pointerEncoder != null && nativeAddress != 0;
  // PROBE 2 (jank-rootcause-analysis.md §6): which encode arm this item took.
  // `byte` means the caller handed us a Dart-heap buffer, which the byte
  // encoder must copy with `TransferableTypedData.fromList` ON THIS ISOLATE
  // before it can ship it to a worker; `pointer` skips that copy entirely.
  // Until this tag existed the split had to be inferred from the ratio of
  // `pool.materialize|type=encode` lines to decodes.
  if (PerfLog.enabled) {
    PerfLog.log(
      'reencode.submit|id=$reencodeId'
      '|path=${usePointer ? "pointer" : "byte"}'
      '|bytes=${fullRes.rgba.lengthInBytes}',
    );
  }
  final reencodeStartUs = PerfLog.enabled ? PerfLog.us : 0;
  try {
    if (usePointer) {
      jpeg = await pointerEncoder(
        nativeAddress: nativeAddress,
        width: fullRes.width,
        height: fullRes.height,
        quality: quality,
        keepAlive: keepAlive,
      );
    } else {
      // PROBE 3 (jank-rootcause-analysis.md §6). The byte encoder's
      // `TransferableTypedData.fromList` copy runs SYNCHRONOUSLY on the
      // calling isolate, before the encoder's first `await` (ceyx
      // `encode_service.dart` `_encode`: the copy precedes the `Isolate.run`).
      // So the wall time of the un-awaited call IS that copy, and separating
      // it from the awaited total is what tells an on-isolate block apart from
      // worker time. Deliberately NOT awaited on this line -- awaiting here
      // would measure the whole encode and defeat the probe.
      final copyStartUs = PerfLog.enabled ? PerfLog.us : 0;
      final pending = encoder(
        fullRes.rgba,
        width: fullRes.width,
        height: fullRes.height,
        quality: quality,
      );
      if (PerfLog.enabled) {
        PerfLog.log(
          'reencode.copy|id=$reencodeId'
          '|dur_us=${PerfLog.us - copyStartUs}'
          '|bytes=${fullRes.rgba.lengthInBytes}',
        );
      }
      jpeg = await pending;
    }
  } catch (_) {
    if (PerfLog.enabled) {
      PerfLog.log(
        'reencode.end|id=$reencodeId'
        '|dur_us=${PerfLog.us - reencodeStartUs}|bytes=0',
      );
    }
    reencodeFallbacks++;
    return await fallback();
  }
  if (PerfLog.enabled) {
    PerfLog.log(
      'reencode.end|id=$reencodeId'
      '|dur_us=${PerfLog.us - reencodeStartUs}|bytes=${jpeg.length}',
    );
  }
  if (jpeg.isEmpty) {
    reencodeFallbacks++;
    return await fallback();
  }

  return EncodedPayload(jpeg);
}
