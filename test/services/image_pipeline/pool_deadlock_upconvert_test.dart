import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:ffi/ffi.dart' show malloc;
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

/// TC-1382..TC-1387 — the 2026-09-21 two-slot hold-and-wait deadlock.
///
/// The defect: one item needs TWO buffers at once (the converter reads a
/// yuv420 source and writes an rgba8 destination in a single native call), and
/// both came from ONE pool whose `acquire` waits untimed at the cap. At
/// N >= cap every holder waited for a slot only another holder could return.
/// Observed in production as `checkedOut=8 waiters=11 idle=0` with ZERO
/// upconverts completing (`docs/logs/2026-09-21/h5-farm-verdict.md`).
///
/// EVERY test below hangs forever on the pre-fix code rather than failing --
/// that is the shape of the defect -- so each is wrapped in a timeout, which
/// is what converts the hang into a red test instead of a stuck suite.
///
/// FAKE WARNING (architect §5): a frame with `nativeAddress == 0` takes the
/// STAGING arm, not the production pointer arm. Tests that mean to exercise
/// the production path must carry a NON-ZERO address and
/// `CeyxOutputFormat.yuv420`, or they pass without executing it. Both arms are
/// covered here, deliberately and separately.
void main() {
  final pool = CeyxNativeBufferPool.shared;

  /// Writes a recognisable pattern so "converted or not" is decidable, and is
  /// an injection point for the native entry, never a Dart reimplementation of
  /// the colour maths (SR-11).
  void spyConverter({
    required int srcAddress,
    required int srcCapacity,
    required int dstAddress,
    required int dstCapacity,
    required int width,
    required int height,
  }) {
    ffi.Pointer<ffi.Uint8>.fromAddress(
      dstAddress,
    ).asTypedList(dstCapacity).fillRange(0, dstCapacity, 0xFF);
  }

  /// Slots held to force the cap, released in tearDown even on failure.
  final held = <CeyxNativeBuffer>[];
  final mallocked = <int>[];

  /// Drives the pool to `checkedOut == maxBuffers` with `idle == 0`, which is
  /// the precondition the production stall was observed in.
  void exhaustPool(int bytes) {
    while (held.length < pool.maxBuffers) {
      final slot = pool.acquireOrNull(bytes);
      expect(
        slot,
        isNotNull,
        reason: 'the pool refused a slot before reaching its own cap',
      );
      held.add(slot!);
    }
    expect(pool.debugIdleCount, 0, reason: 'precondition: no idle slot left');
  }

  setUp(() {
    debugUpconvertConverter = spyConverter;
  });

  tearDown(() {
    for (final slot in held) {
      pool.release(slot);
    }
    held.clear();
    for (final address in mallocked) {
      malloc.free(ffi.Pointer<ffi.Uint8>.fromAddress(address));
    }
    mallocked.clear();
    debugResetUpconvertSeam();
  });

  /// A frame on the PRODUCTION pointer arm: real native address, yuv420.
  DecodedRgba nativeYuvFrame(int w, int h) {
    final bytes = ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h);
    final address = malloc<ffi.Uint8>(bytes).address;
    mallocked.add(address);
    final view = ffi.Pointer<ffi.Uint8>.fromAddress(
      address,
    ).asTypedList(bytes);
    return DecodedRgba(
      rgba: view,
      width: w,
      height: h,
      format: CeyxOutputFormat.yuv420,
      nativeAddress: address,
    );
  }

  /// A frame on the STAGING arm: no address, so `materialiseRgba` must take a
  /// SECOND pool buffer for the source while already holding the destination.
  DecodedRgba heapYuvFrame(int w, int h) => DecodedRgba(
        rgba: Uint8List(
          ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h),
        ),
        width: w,
        height: h,
        format: CeyxOutputFormat.yuv420,
      );

  test(
    'TC-1382: materialiseRgba completes with the pool at its cap and no idle '
    'slot (pre-fix: waits forever for a destination)',
    () async {
      exhaustPool(4096);
      final before = pool.debugUnpooledAllocations + pool.debugAdoptions;

      final out = await materialiseRgba(nativeYuvFrame(8, 8));

      expect(
        out.rgba.length,
        ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, 8, 8),
        reason: 'the destination is rgba8-sized',
      );
      expect(
        out.rgba.every((b) => b == 0xFF),
        isTrue,
        reason: 'the converter wrote into the escape buffer, so the caller '
            'got converted pixels and not the planar source',
      );
      expect(
        pool.debugUnpooledAllocations + pool.debugAdoptions,
        before + 1,
        reason: 'exactly ONE escape allocation: the destination. A second one '
            'would mean the source arm escaped too, which this frame (real '
            'native address) must not need.',
      );
      expect(
        pool.debugWaitsForCapacity,
        0,
        reason: 'the fix deletes the WAIT; any wait recorded here means an '
            'acquire path still blocks on this pool while holding one of its '
            'buffers',
      );

      out.releaseNative?.call();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'TC-1383: the staging arm (nativeAddress == 0) also completes at the cap '
    '— the second, quieter double-acquire',
    () async {
      exhaustPool(4096);
      final before = pool.debugUnpooledAllocations + pool.debugAdoptions;

      final out = await materialiseRgba(heapYuvFrame(8, 8));

      expect(out.rgba.every((b) => b == 0xFF), isTrue);
      expect(
        pool.debugUnpooledAllocations + pool.debugAdoptions,
        before + 2,
        reason: 'this arm needs TWO buffers at the cap — destination AND the '
            'staged source — and both must escape rather than wait',
      );
      out.releaseNative?.call();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'TC-1384: N > cap concurrent upconverts all complete, none waits',
    () async {
      const n = 12; // > maxBuffers (8), the production repro's shape
      final waitsBefore = pool.debugWaitsForCapacity;
      final frames = List.generate(n, (_) => nativeYuvFrame(8, 8));

      final results = await Future.wait(
        frames.map(materialiseRgba),
      );

      expect(results.length, n);
      for (final out in results) {
        expect(
          out.rgba.every((b) => b == 0xFF),
          isTrue,
          reason: 'every item must end up with converted pixels a consumer '
              'can read — the production symptom was that none did',
        );
      }
      expect(
        pool.debugWaitsForCapacity - waitsBefore,
        0,
        reason: 'a non-zero wait count means the two bounds disagree '
            '(native_buffer_pool.dart:73-76). Report it, do not relax this.',
      );
      expect(pool.debugWaiterCount, 0, reason: 'no acquirer left blocked');

      for (final out in results) {
        out.releaseNative?.call();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'TC-1385: no leak after the N > cap run drains',
    () async {
      final checkedOutBefore = pool.debugCheckedOut;
      final finalizerBefore = pool.debugFinalizerReleases;

      final frames = List.generate(12, (_) => nativeYuvFrame(8, 8));
      final results = await Future.wait(frames.map(materialiseRgba));
      for (final out in results) {
        out.releaseNative?.call();
      }

      expect(
        pool.debugCheckedOut,
        checkedOutBefore,
        reason: 'every destination — pooled or escaped — came back',
      );
      expect(
        pool.debugFinalizerReleases,
        finalizerBefore,
        reason: 'the finalizer is a defect counter, not a statistic: a '
            'GC-dependent return means an explicit release site is missing',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'TC-1386: idle-shrink still sees an escaped buffer as outstanding',
    () async {
      exhaustPool(4096);
      final out = await materialiseRgba(nativeYuvFrame(8, 8));

      expect(
        pool.hasOutstandingCheckouts,
        isTrue,
        reason: 'an escaped destination is still pool-OWNED, so a shrink must '
            'not run while one is live',
      );

      out.releaseNative?.call();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'TC-1387 (D-2): a deferred decode charges the lane its REAL peak, not 0',
    () {
      final frame = DecodedRgba(
        rgba: Uint8List(
          ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, 100, 50),
        ),
        width: 100,
        height: 50,
        format: CeyxOutputFormat.yuv420,
        nativeAddress: 1,
      );
      final deferred = (
        encodedPayload: null,
        pixelFallback: null,
        rawDecodeRan: true,
        fullRes: null,
        observedCost: SourceCost.expensive,
        deferred: false,
        exifOrientation: null,
        failureCode: null,
        nativeAddress: 1,
        nativeKeepAlive: null,
        pendingUpconvert: (frame: frame, exifOrientation: 1, longEdge: 2800),
      );

      expect(
        ImagePreloadController.deferredUpconvertPeakBytes(deferred),
        frame.rgba.lengthInBytes + 100 * 50 * 4,
        reason: 'planar + the rgba8 destination it will hold at the same time',
      );

      final notDeferred = (
        encodedPayload: null,
        pixelFallback: null,
        rawDecodeRan: false,
        fullRes: null,
        observedCost: SourceCost.cheap,
        deferred: false,
        exifOrientation: null,
        failureCode: null,
        nativeAddress: 0,
        nativeKeepAlive: null,
        pendingUpconvert: null,
      );
      expect(
        ImagePreloadController.deferredUpconvertPeakBytes(notDeferred),
        isNull,
        reason: 'SCOPE GUARD: non-deferred sizing must be untouched by D-2',
      );
    },
  );
}
