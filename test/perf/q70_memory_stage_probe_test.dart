// TC-1398 -- q70 per-stage memory probe (the maintained successor of the
// scratch harnesses tmp/verify/q70-atlas/harness/ and tmp/verify/q70-peak/
// harness/; stage table and findings F1-F4 in tmp/verify/q70-atlas/
// measurements.md, F2 attribution in tmp/verify/q70-peak/attribution.md).
//
// Drives the PRODUCTION ImagePreloadController (8 decode lanes, real ceyx
// yuv420 decode, real native q70 encode, real ImageCache publish) over ONE
// preload of three real 24 MP ARW frames, sampling the pool / ledger / cache
// gauges every 5 ms, then asserts INVARIANTS on the deterministic counters
// only. Process-level numbers (phys_footprint, vmmap) were diagnosis tooling
// and are deliberately absent. One SUMMARY line is printed so a run doubles as
// a measurement.
//
// HOW TO RUN (`flutter test` loads no native library without the override,
// same mechanism as yuv420_pointer_encode_native_test.dart):
//
//   DNG_NATIVE_BUILD_DIR=/Users/jhangyu/project/ceyx/plugin/macos/Libraries \
//     flutter test test/perf/q70_memory_stage_probe_test.dart
//
// SKIPS (loudly, with a reason) when DNG_NATIVE_BUILD_DIR is unset or the
// external corpus below is not mounted. A skipped run and a real run differ
// only in the skip line: cite a PASSING count, never a bare exit 0.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/dart_image_loader.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

// Sony ILCE-7C, 6024x4024 decoded. One orientation-1 frame and two
// orientation-8 frames, so both the plain and the oriented decoder run.
const _corpusDir = '/Volumes/EVO_4T/2025-11-08';
const _files = [
  '2025-11-08-15-13-43.ARW',
  '2025-11-08-15-24-59.ARW',
  '2025-11-08-15-25-01.ARW',
];

// Fixed, not the host's: the atlas ran at 256 GiB, and the ledger/cache
// budgets derived from it must not vary per machine.
const _physicalMemoryBytes = 256 * 1024 * 1024 * 1024;
const _laneWidth = 8;

final String? _nativeDir = Platform.environment['DNG_NATIVE_BUILD_DIR'];

final String? _skipReason = _nativeDir == null
    ? 'set DNG_NATIVE_BUILD_DIR to ceyx plugin/macos/Libraries: this probe '
        'decodes real RAW files through the native library'
    : !_files.every((f) => File('$_corpusDir/$f').existsSync())
        ? 'external RAW corpus absent: $_corpusDir/{${_files.join(',')}}'
        : null;

typedef _U64x5N = Int32 Function(Pointer<Uint64>, Pointer<Uint64>,
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _U64x5D = int Function(Pointer<Uint64>, Pointer<Uint64>,
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _GetN = Uint64 Function();
typedef _GetD = int Function();

/// ceyx native counters the Dart API does not expose. A missing symbol
/// throws: a binary without the counters cannot back any claim below.
({int fused, int arenaBytes, int arenaLanes}) _readNative(DynamicLibrary lib) {
  final p = calloc<Uint64>(5);
  try {
    final rc = lib.lookupFunction<_U64x5N, _U64x5D>(
        'ceyx_debug_persistent_device_arena_counters')(
      p, p + 1, p + 2, p + 3, p + 4);
    expect(rc, 0, reason: 'arena counters unavailable');
    return (
      // C++ symbol, looked up mangled (the atlas did the same).
      fused: lib.lookupFunction<_GetN, _GetD>(
          '_Z28raw_fused_bayer_render_countv')(),
      arenaBytes: p[3], // resident_device_bytes
      arenaLanes: p[4], // live_lanes
    );
  } finally {
    calloc.free(p);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TC-1398 q70 per-stage memory invariants over a real 8-lane decode',
      () async {
    final native =
        DynamicLibrary.open('$_nativeDir/libdng_decoder_native.dylib');
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes =
        imageCacheBudgetBytes(physicalMemoryBytes: _physicalMemoryBytes);
    final pool = CeyxNativeBufferPool.shared;

    var decodes = 0, encodes = 0, encInflight = 0;
    var frameW = 0, frameH = 0;
    Future<DecodedRgba> track(Future<DecodedRgba> f) async {
      decodes++;
      final d = await f;
      frameW = d.width;
      frameH = d.height;
      return d;
    }

    Future<DecodedRgba> dec(String p) => track(decodeDngFull(p));
    final controller = ImagePreloadController(
      imageLoader: dartImageLoad,
      dngDecoder: dec,
      orientingDngDecoder: (p, {required int exifOrientation}) =>
          track(decodeDngFullOriented(p, exifOrientation: exifOrientation)),
      deferredEncodeDecoder: () => dec,
      // Counting wrapper, byte-identical to the controller's private
      // _encodeJpegFromNativeYuv420.
      pointerYuv420PayloadEncoder: ({
        required int nativeAddress,
        required int srcCapacity,
        required int width,
        required int height,
        required int quality,
        Object? keepAlive,
      }) async {
        encodes++;
        encInflight++;
        try {
          return await CeyxEncodeService().encodeJpegFromNativeYuv420(
            srcAddress: nativeAddress,
            srcCapacity: srcCapacity,
            width: width,
            height: height,
            quality: quality,
            keepAlive: keepAlive is Finalizable ? keepAlive : null,
          );
        } finally {
          encInflight--;
        }
      },
      retention: retentionPolicyFor(physicalMemoryBytes: _physicalMemoryBytes),
      physicalMemoryBytes: _physicalMemoryBytes,
      decodeLaneWidth: _laneWidth,
      // Headless stand-in for the app's IdlePublishScheduler: one pacer drain
      // per 16 ms "frame". Without it the pacer falls back to
      // SchedulerBinding frames, which never run in a headless test(), and
      // every non-exempt (+/-1 neighbour) tier-2 publish stays queued
      // (atlas run r3).
      scheduleFrameCallback: (cb) =>
          Timer(const Duration(milliseconds: 16), cb),
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(2880, 1800);

    final items = [
      for (final f in _files)
        PhotoItem(id: '$_corpusDir/$f', files: [File('$_corpusDir/$f')]),
    ];

    final n0 = _readNative(native);
    final pub0 = controller.debugPayloadDecodePublishCount;
    final fileFb0 = controller.debugBandEntryFileDecodeCount;
    final alloc0 = pool.debugAllocations;
    final unpooled0 = pool.debugUnpooledAllocations;
    final waits0 = pool.debugWaitsForCapacity;
    expect(debugUpconvertCount, 0);
    expect(debugUpconvertPoolAcquireCount, 0);

    var hwCheckedOut = 0, hwCheckedOutBytes = 0, hwLive = 0;
    var hwDecodeLedger = 0, hwCache = 0;
    void sample() {
      hwCheckedOut = max(hwCheckedOut, pool.debugCheckedOut);
      hwCheckedOutBytes = max(hwCheckedOutBytes, pool.debugLiveBufferByteTotal);
      hwLive = max(hwLive, pool.debugLiveBuffers);
      hwDecodeLedger = max(hwDecodeLedger, controller.debugDecodeInflightBytes);
      hwCache = max(hwCache, cache.currentSizeBytes);
    }

    final sampler =
        Timer.periodic(const Duration(milliseconds: 5), (_) => sample());
    final sw = Stopwatch()..start();
    unawaited(controller.preloadImages(
        items: items, selectedItemId: items[1].id, notifyLoaded: () {}));

    // Settle: the +/-1 band (all three items) has published and every stage
    // has been quiet for 100 ms. Deliberately NOT gated on the decode ledger
    // reaching 0 -- see F2 below (atlas run r2 timed out waiting on it).
    var quiet = 0;
    while (quiet < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final busy = controller.debugPayloadDecodePublishCount - pub0 <
              _files.length ||
          controller.debugDecodeLaneRunningCount > 0 ||
          controller.debugEncodeStageRunningCount > 0 ||
          cache.pendingImageCount > 0 ||
          encInflight > 0;
      quiet = busy ? 0 : quiet + 1;
      if (sw.elapsed > const Duration(seconds: 20)) {
        fail('did not settle in 20 s: decodes=$decodes encodes=$encodes '
            'pubDelta=${controller.debugPayloadDecodePublishCount - pub0}');
      }
    }
    sampler.cancel();
    sample();
    final settleMs = sw.elapsedMilliseconds;
    final n1 = _readNative(native);

    final planar =
        ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, frameW, frameH);
    final rgbaBytes = frameW * frameH * 4;
    final pubDelta = controller.debugPayloadDecodePublishCount - pub0;
    final fusedDelta = n1.fused - n0.fused;
    final decodeLedger = controller.debugDecodeInflightBytes;
    final ledger = controller.debugMemoryLedgerSnapshot;
    debugPrint('Q70MEM|SUMMARY settleMs=$settleMs frame=${frameW}x$frameH '
        'decodes=$decodes encodes=$encodes fusedDelta=$fusedDelta '
        'upconv=$debugUpconvertCount/$debugUpconvertPoolAcquireCount '
        'pubDelta=$pubDelta '
        'fileFbDelta=${controller.debugBandEntryFileDecodeCount - fileFb0} '
        'poolHw(co=$hwCheckedOut coBytes=$hwCheckedOutBytes live=$hwLive '
        'cap=${pool.maxBuffers}) '
        'poolAllocDelta=${pool.debugAllocations - alloc0} '
        'unpooledDelta=${pool.debugUnpooledAllocations - unpooled0} '
        'waitsDelta=${pool.debugWaitsForCapacity - waits0} '
        'arena=${n1.arenaBytes}/${n1.arenaLanes}lanes '
        'decodeLedgerHw=$hwDecodeLedger/'
        '${controller.debugDecodeInflightByteBudget} '
        'decodeLedgerSettled=$decodeLedger '
        'tailSettled=${ledger.encodePublishTailBytes} '
        'payloadBytes=${ledger.retainedPayloadBytes} '
        'cacheBytes=${cache.currentSizeBytes} cacheHw=$hwCache');

    // Every band item came through the RAW path, once.
    expect(decodes, _files.length, reason: 'F1: RAW path not taken?');
    expect(frameW * frameH, 6024 * 4024);

    // Stage 1/1b: every decode took the fused Bayer render (no Stage-3 RGB16
    // region), and the arena holds only the 2 B/px mosaic per live lane --
    // a Stage-3 region would add ~6 B/px.
    expect(fusedDelta, decodes);
    expect(n1.arenaLanes, inInclusiveRange(1, _laneWidth));
    expect(n1.arenaBytes, lessThan(n1.arenaLanes * frameW * frameH * 3));

    // Stage 2: pooled planar slots, bounded by the pool cap, never unpooled,
    // never waited for.
    expect(hwCheckedOut, inInclusiveRange(1, pool.maxBuffers));
    expect(hwLive, lessThanOrEqualTo(pool.maxBuffers));
    expect(hwCheckedOutBytes, greaterThanOrEqualTo(planar));
    // Slot capacity = planar rounded up to 16 KiB (measurements.md stage 2).
    expect(hwCheckedOutBytes,
        lessThanOrEqualTo(hwCheckedOut * (planar + 16 * 1024)));
    expect(pool.debugUnpooledAllocations - unpooled0, 0);
    expect(pool.debugWaitsForCapacity - waits0, 0);
    expect(pool.debugAllocations - alloc0, lessThanOrEqualTo(pool.maxBuffers));
    expect(pool.debugCheckedOut, 0, reason: 'a slot stayed checked out');

    // Stage 3: one native q70 encode per decode.
    expect(encodes, decodes);

    // Stage 4 (deleted upconvert): the identity path never materialises RGBA.
    expect(debugUpconvertCount, 0);
    expect(debugUpconvertPoolAcquireCount, 0);

    // Stage 4b/5b: tier-2 is served ONLY by payload-decode publishes (+/-1
    // band = 3), never by a file re-decode, and the ImageCache holds exactly
    // those full-size images.
    expect(pubDelta, _files.length);
    expect(controller.debugBandEntryFileDecodeCount - fileFb0, 0);
    expect(cache.currentSizeBytes, pubDelta * rgbaBytes);

    // Stage 5: payloads are retained, and far below the planar frame.
    expect(ledger.retainedPayloadBytes, greaterThan(0));
    expect(ledger.retainedPayloadBytes, lessThan(decodes * planar));

    // Stage 6: the admission ledger charges planar bytes (not RGBA) and
    // never exceeds its budget.
    expect(hwDecodeLedger, inInclusiveRange(planar,
        controller.debugDecodeInflightByteBudget));
    expect(ledger.encodePublishTailBytes, 0);
    // F2 (measurements.md; attribution.md section 5), PINNED AS-IS, NOT
    // FIXED: after settle the decode ledger keeps a stranded charge of whole
    // planar frames. The atlas saw 1-2 of 23 (with a `halcyon.claim.dup`
    // line); this 3-frame workload strands anywhere from 0 to all 3, run to
    // run, with NO dup line, and a stranded value stays put for >= 3 s after
    // settle (tmp/verify/q70-memopt/diag-f2.txt), so it is not release lag.
    // Accounting only -- no pool slot is held (asserted above: checkedOut ==
    // 0) -- but it eats admission headroom. Once F2 is fixed, tighten to
    // `equals(0)`.
    expect(decodeLedger % planar, 0, reason: 'F2 residual not whole frames');
    expect(decodeLedger ~/ planar, inInclusiveRange(0, decodes));

    // Positive control, AFTER every reading above: the upconvert counters can
    // move (a 16x16 synthetic planar frame through the real converter), so
    // their zero is evidence.
    final rgba = await materialiseRgba(DecodedRgba(
      rgba: Uint8List(
          ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, 16, 16)),
      width: 16,
      height: 16,
      format: CeyxOutputFormat.yuv420,
    ));
    rgba.releaseNative?.call();
    expect(debugUpconvertCount, 1, reason: 'positive control');
  }, skip: _skipReason, timeout: const Timeout(Duration(seconds: 60)));
}
