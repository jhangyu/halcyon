// Deliverable 2 (docs/logs/2026-09-03/decode-jank-remediation-contract.md):
// EXIF-orientation compositing no longer runs immediately on decode-result
// arrival; it waits for a pacing slot. TC-XX11 .. TC-XX14.
//
// THE OWNERSHIP ARGUMENT, asserted here: the slot is awaited BEFORE any
// `ui.Image` exists, so a slow or never-granted slot cannot leak a handle.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';

/// A 2x2 OPAQUE source. Alpha must be 0xFF: both identity short-circuits
/// assert `_sampledOpaque`, so a transparent fixture would fail inside that
/// assert instead of in the assertion under test.
DecodedRgba _source() {
  final bytes = Uint8List(2 * 2 * 4);
  for (var p = 0; p < 4; p++) {
    bytes[p * 4] = 10 + p * 20; // R carries a marker
    bytes[p * 4 + 3] = 0xFF;
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 2);
}

/// A gate the test opens by hand. `requests` counts slot requests, so
/// "gated exactly once" and "never gated" are both directly assertable.
class ManualGate {
  final List<Completer<void>> _waiting = [];
  int requests = 0;

  Future<void> call() {
    requests++;
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  void openAll() {
    final due = List<Completer<void>>.of(_waiting);
    _waiting.clear();
    for (final completer in due) {
      completer.complete();
    }
  }
}

/// Pumps real, zero-duration timers/microtasks -- what would let a pending
/// future settle if nothing else were blocking it.
Future<void> _pumpEventLoop([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-XX11 -- THE AC2 test. Delete the `await gate()` line in
  // `decodedRgbaToOrientedFullRes` and this case fails.
  //
  // NOTE: this deviates from the plan's literal `doesNotComplete` matcher --
  // that matcher registers a permanent `future.then(fail)` listener for the
  // rest of the test (see package:matcher `_DoesNotComplete.matches`), which
  // is incompatible with this same test later opening the gate and awaiting
  // the very future it was applied to (it would then always fail, by
  // matcher design, regardless of implementation correctness). A manual
  // "has it settled yet" flag captures the identical AC2 assertion --
  // "compositing must not run before a slot is granted" -- without that
  // conflict.
  test('a non-identity orientation waits for the gate before compositing',
      () async {
    final gate = ManualGate();
    var settled = false;
    final pending = decodedRgbaToOrientedFullRes(
      _source(),
      exifOrientation: 6, // 90 CW -- a real GPU pass
      gate: gate.call,
    ).then((value) {
      settled = true;
      return value;
    });

    await _pumpEventLoop();
    expect(
      settled,
      isFalse,
      reason: 'compositing must not run before a slot is granted',
    );
    expect(gate.requests, 1);

    gate.openAll();
    final result = await pending;
    expect(settled, isTrue);
    expect(result.width, 2);
    expect(result.height, 2);
    expect(
      result.image,
      isNotNull,
      reason: 'a GPU pass ran, so a handle came back',
    );
    result.image!.dispose();
  });

  // TC-XX12 -- AC7: the no-op orientation composites nothing, so it must not
  // even ask for a slot (asking would add latency for zero work).
  test('orientation 1 never asks the gate for a slot', () async {
    final gate = ManualGate();

    final fullRes = await decodedRgbaToOrientedFullRes(
      _source(),
      exifOrientation: 1,
      gate: gate.call,
    );
    expect(fullRes.image, isNull, reason: 'identity short-circuit, no GPU pass');

    final payload = await decodedRgbaToPixelPayload(
      _source(),
      exifOrientation: 1,
      longEdge: 0, // no downscale either
      gate: gate.call,
    );
    expect(payload.width, 2);

    final image = await decodedRgbaToImage(_source(), exifOrientation: 1);
    addTearDown(image.dispose);

    expect(gate.requests, 0, reason: 'AC7: orientation 1 skips compositing entirely');
  });

  // TC-XX13
  test('the gate is requested exactly once per oriented full-res decode',
      () async {
    final gate = ManualGate();
    final pending = decodedRgbaToImage(
      _source(),
      exifOrientation: 8, // 90 CCW
      gate: gate.call,
    );
    gate.openAll();
    final image = await pending;
    addTearDown(image.dispose);

    expect(gate.requests, 1, reason: 'one compositing pass buys one slot');
  });

  // TC-XX14 -- the pixel-payload path also uploads and composites, so its GPU
  // pass is paced too (a 200px downscale of a 50MB frame is not free).
  test('a pixel-payload downscale waits for the gate', () async {
    final gate = ManualGate();
    var settled = false;
    final pending = decodedRgbaToPixelPayload(
      _source(),
      exifOrientation: 1,
      longEdge: 1, // forces a real downscale pass past the short-circuit
      gate: gate.call,
    ).then((value) {
      settled = true;
      return value;
    });

    await _pumpEventLoop();
    expect(settled, isFalse);
    expect(gate.requests, 1);

    gate.openAll();
    final payload = await pending;
    expect(payload.width, 1);
    expect(payload.height, 1);
  });
}
