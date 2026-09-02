import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'payload_reencoder.dart';
import 'photo_payload.dart';

/// A bitstream at or under this size passes through untouched.
///
/// Below this, a full decode + re-encode spends ~100ms of CPU and a
/// full-resolution RGBA buffer to save a fraction of half a megabyte. It is
/// also the single lever that turns normalisation OFF for embedded JPEGs
/// (plan §1.1 option B): raise it above the largest embedded JPEG and those
/// files are retained as-is, with no code deleted.
const int kNormalizePassthroughMaxBytes = 512 * 1024;

/// Decodes an encoded bitstream to FULL-SIZE RGBA8, or null on any failure.
typedef EncodedRgbaDecoder =
    Future<({Uint8List rgba, int width, int height})?> Function(
      Uint8List encoded,
    );

/// How many times normalisation degraded to the original bytes because the
/// input could not be turned into a q70 payload -- i.e. the passthrough-size
/// bitstream was decoded but re-encoding it via [reencodePayload] failed for
/// any of that function's reasons (undecodable, dimension mismatch, encoder
/// exception). Those cases share `reencodeFallbacks` (`payload_reencoder.dart`,
/// amendment E-M1) rather than duplicating a second counter for the same
/// event; this counter is reserved for normalisation's OWN refusal (the
/// output-not-smaller-than-input rule) that `reencodePayload` knows nothing
/// about.
@visibleForTesting
int normalizeFallbacks = 0;

@visibleForTesting
void resetNormalizeCounters() {
  normalizeFallbacks = 0;
}

/// Test-only replacement for [decodeEncodedToRgba].
///
/// A library field, not a constructor parameter on `PhotoSource`: the engine
/// codec is unavailable in a plain unit test, and threading a decoder through
/// `PhotoSource` would widen a production seam for a test-only reason. Task 3
/// is the consumer; it is declared here so the seam lives with the thing it
/// replaces.
@visibleForTesting
EncodedRgbaDecoder? debugEncodedRgbaDecoderOverride;

/// Bounds how many normalisations hold a full-resolution RGBA buffer at once.
///
/// Cheap items load in PARALLEL across the whole retention window, and one
/// 7008x4672 frame is ~131 MB of RGBA (measured, `payload-bench-report.md`).
/// Without this, a 9-slot window of JPGs would hold nine of them at once.
/// At the default width of 2, the transient ceiling this gate itself
/// contributes is DERIVED (not measured): 2 x 131 MB =~ 262 MB, on top of
/// whichever lane decodes and payload-budget bytes are resident at the same
/// moment.
///
/// Widening takes effect for the next acquirer; NARROWING never pre-empts a
/// body already running -- the same rule `DecodeLane.width` follows, for the
/// same reason (nothing in flight is cancellable).
class NormalizeGate {
  NormalizeGate({int width = 2}) : _width = width < 1 ? 1 : width;

  int _width;
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  int get width => _width;

  set width(int value) {
    _width = value < 1 ? 1 : value;
    _admit();
  }

  /// How many bodies are executing right now.
  int get runningCount => _running;

  /// PERMIT TRANSFER, not "wake up and take a slot": a body that waits has its
  /// slot accounted for by [_admit] at the moment it is released. If the
  /// resumed body incremented `_running` itself there would be a gap between
  /// release and resume in which `_running` under-reports, and a second
  /// `_admit` in that gap would over-issue permits.
  Future<T> run<T>(Future<T> Function() body) async {
    if (_running < _width) {
      _running++;
    } else {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future; // the permit is already counted in `_running`
    }
    try {
      return await body();
    } finally {
      _running--;
      _admit();
    }
  }

  void _admit() {
    while (_running < _width && _waiting.isNotEmpty) {
      _running++;
      _waiting.removeFirst().complete();
    }
  }
}

/// The process-wide gate. One per process because the thing it bounds --
/// resident full-resolution RGBA -- is a process-wide resource.
///
/// No production wiring sets [NormalizeGate.width] from the decode lane's
/// width: the gate keeps its own default and the two are independently
/// configured (amendment E-M2).
final NormalizeGate normalizeGate = NormalizeGate();

/// Production [EncodedRgbaDecoder]: the engine's own codec, full size.
Future<({Uint8List rgba, int width, int height})?> decodeEncodedToRgba(
  Uint8List encoded,
) async {
  ui.Image? image;
  try {
    final codec = await ui.instantiateImageCodec(encoded);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return (
      rgba: data.buffer.asUint8List(),
      width: image.width,
      height: image.height,
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}

/// Turns an ENCODED bitstream into the same q70 full-resolution JPEG payload
/// the RAW sensor path produces, so a JPG, an embedded preview and a decoded
/// RAW are literally the same cache citizen at the same quality.
///
/// USER RULING 2026-08-30 (contract D5): "ALL items (RAW & JPG) full-size
/// decode -> q70 re-encode -> ONE shared payload cache". This is the half of
/// that ruling that covers items which never reach the sensor decoder.
///
/// Amendment E-M1: the decode-success path (dimension guard, encoder
/// exception, empty output) is NOT duplicated here -- it delegates to
/// [reencodePayload], which already implements those guards and owns
/// `reencodeFallbacks`. This function keeps only its OWN two rules: the
/// small-input passthrough, and the "never make a payload bigger" refusal,
/// which `reencodePayload` has no opinion on because it never receives the
/// original encoded length to compare against.
///
/// Every failure returns the ORIGINAL bytes unchanged. Normalisation is an
/// optimisation of what we retain, never a gate on whether the item is
/// displayable: a failure here must leave the item exactly as renderable as
/// it was, and must never produce a permanent miss.
Future<SourcePayload> normalizeEncodedPayload({
  required Uint8List encoded,
  required PayloadEncoder encoder,
  int quality = kReencodeJpegQuality,
  EncodedRgbaDecoder? decodeToRgba,
  NormalizeGate? gate,
}) async {
  // Resolved at call time, not as a default argument: Task 3 needs an
  // override seam that `PhotoSource` does not thread through its own
  // constructor, and a default argument cannot be replaced from outside.
  final decode =
      decodeToRgba ?? debugEncodedRgbaDecoderOverride ?? decodeEncodedToRgba;
  if (encoded.lengthInBytes <= kNormalizePassthroughMaxBytes) {
    return EncodedPayload(encoded);
  }
  final effectiveGate = gate ?? normalizeGate;
  final fallback = EncodedPayload(encoded);
  // ROUTING DIAGNOSTIC v2 (2026-09-02, h3). Every CHEAP item over the
  // passthrough size pays a full-resolution decode plus a native re-encode
  // here, and `normalizeGate` admits only two at a time -- so a cheap item can
  // land seconds late with no RAW decode anywhere in sight. `queuedMs`
  // separates "waiting for a gate permit" from "doing the work", which is the
  // distinction a user-perceived "this photo was slow" cannot make on its own.
  final tQueued = DateTime.now();
  return effectiveGate.run(() async {
    final tStart = DateTime.now();
    final queuedMs = tStart.difference(tQueued).inMilliseconds;
    final decoded = await decode(encoded);
    final decodeMs = DateTime.now().difference(tStart).inMilliseconds;
    final result = await reencodePayload(
      encoder: encoder,
      fallback: fallback,
      fullRes: decoded,
      quality: quality,
    );
    debugPrint(
      'halcyon.route.normalize|inBytes=${encoded.lengthInBytes}'
      '|px=${decoded == null ? 'null' : '${decoded.width}x${decoded.height}'}'
      '|queuedMs=$queuedMs|decodeMs=$decodeMs'
      '|totalMs=${DateTime.now().difference(tStart).inMilliseconds}'
      '|outBytes=${result is EncodedPayload ? result.bytes.lengthInBytes : -1}',
    );
    if (identical(result, fallback)) {
      // reencodePayload already degraded to our own fallback and already
      // counted it in `reencodeFallbacks` -- nothing left for us to do.
      return result;
    }
    if (result is EncodedPayload &&
        result.bytes.lengthInBytes >= encoded.lengthInBytes) {
      // Never make a payload bigger. A camera JPEG already smaller than our
      // q70 output is one worth keeping exactly as it is. This refusal is
      // normalisation-specific: `reencodePayload` never sees the original
      // encoded length, only the caller does.
      normalizeFallbacks++;
      return fallback;
    }
    return result;
  });
}
