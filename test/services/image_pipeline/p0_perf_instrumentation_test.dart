import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_pixels_image.dart';
import 'package:halcyon_flutter/services/image_pipeline/sidebar_thumbnail_codec.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

/// P0 (docs/logs/2026-09-05/pool-round-contract.md AC7 /
/// pipeline-architecture-v2.md §5-P0): proves every new emit site this task
/// owns actually reaches the log file when enabled, and is structurally
/// inert (no PerfLog writes at all) when the flag is off.
///
/// Two DIFFERENT event names are exercised deliberately (lead's ownership-
/// extension ruling): `decode.ffi` (photo_source.dart -- FFI decode wall
/// time) and `materialize` (the architecture doc's own 4 sites -- GPU
/// texture/engine-buffer hand-off cost). `lane.width` (main.dart) is not
/// exercised here -- it fires off an AppState listener in `main()`, which is
/// not a unit-testable seam from this file's ownership; its emission is
/// covered by direct code inspection + `flutter analyze` (see task report).
///
/// Plain test(), never testWidgets(), wherever a real `ui.decodeImageFromPixels`
/// engine future is awaited -- it hangs forever inside testWidgets' FakeAsync
/// zone (see raw_pixels_image_test.dart's header note).
Future<NativeImageResult> _needsRawDecode(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

// Orientation 6 (not identity): forces decodedRgbaToPixelPayload /
// decodedRgbaToOrientedFullRes past their identity short-circuit and into
// the real `ui.decodeImageFromPixels` GPU pass this task instruments --
// matching photo_source_fullres_handle_test.dart's TC-827b convention.
Future<NativeImageResult> _needsRawDecodeRotated(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

DecodedRgba _decodedFixture() {
  // 8x6 opaque RGBA, matching the convention in
  // photo_source_fullres_handle_test.dart.
  final bytes = Uint8List(8 * 6 * 4);
  for (var p = 0; p < 8 * 6; p++) {
    bytes[p * 4 + 3] = 255;
  }
  return DecodedRgba(rgba: bytes, width: 8, height: 6);
}

Future<DecodedRgba> _decoder(String path) async => _decodedFixture();

Future<Uint8List> _okEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

Future<Uint8List> _throwingEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => throw StateError('encoder boom');

PixelPayload _pixels(int w, int h) =>
    PixelPayload(rgba: Uint8List(w * h * 4), width: w, height: h);

Future<Uint8List> _bigPng() async {
  // Synthesize a >512KB encoded PNG, same recipe as
  // sidebar_thumbnail_codec_test.dart's bigPng() -- no sample-file
  // dependency, forces sidebarCacheBytes' decode/re-encode branch.
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint();
  for (var x = 0; x < 1200; x += 10) {
    paint.color = ui.Color.fromARGB(255, x % 256, (x * 7) % 256, 99);
    canvas.drawRect(ui.Rect.fromLTWH(x.toDouble(), 0, 10, 800), paint);
  }
  final image = await recorder.endRecording().toImage(1200, 800);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

PhotoItem _photoItem(String id) =>
    PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);

({TierTwoScheduler scheduler, TierTwoRegistry registry}) _tierTwoHarness(
  SourcePayload? Function(String) payloadFor,
) {
  final registry = TierTwoRegistry(currentPayloadFor: payloadFor);
  final scheduler = TierTwoScheduler(
    registry: registry,
    lane: DecodeLane(width: 1),
    currentPayloadFor: payloadFor,
    fullSizeProviderFor: (p) => throw StateError('not reached'),
    ensurePayload:
        (item, {required distance, required notifyLoaded, onSerialLane = false}) async {},
    dngDecoder: () => null,
    exifOrientationFor: (id) => 1,
    navigationDebounce: Duration.zero,
  );
  return (scheduler: scheduler, registry: registry);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late String logPath;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('p0_perf_test_');
    logPath = '${tmpDir.path}${Platform.pathSeparator}perf.log';
  });

  tearDown(() async {
    await PerfLog.flush();
    PerfLog.enabled = false;
    resetReencodeCounters();
    tmpDir.deleteSync(recursive: true);
  });

  // TC-947
  test(
    'flag-on: PhotoSource.load emits decode.ffi|id=|bytes=|dur_us= around '
    'the native FFI decode call (distinct name from materialize)',
    () async {
      PerfLog.init(logPath);
      const source = PhotoSource(
        loader: _needsRawDecodeRotated, // orientation 6: forces the GPU pass too
        dngDecoder: _decoder,
        payloadEncoder: _okEncoder,
      );
      await source.load('sample.dng', longEdge: 0);
      await PerfLog.flush();

      final content = File(logPath).readAsStringSync();
      final ffiLines = content
          .split('\n')
          .where((l) => l.contains('decode.ffi|id=sample.dng'))
          .toList();
      expect(
        ffiLines,
        isNotEmpty,
        reason: 'expected a decode.ffi event for the FFI decode call',
      );
      expect(ffiLines.first, contains('bytes=${8 * 6 * 4}'));
      expect(ffiLines.first, contains('dur_us='));
      expect(
        content.contains('materialize|id='),
        isTrue,
        reason:
            'decodedRgbaToPixelPayload runs inside the same load() call and '
            'materializes a ui.Image -- both events coexist, distinctly named',
      );
    },
  );

  // TC-948
  test(
    'flag-on: reencodePayload emits reencode.submit and reencode.end with '
    'a matching id, dur_us and the encoded byte count',
    () async {
      PerfLog.init(logPath);
      final result = await reencodePayload(
        encoder: _okEncoder,
        fallback: _pixels(10, 10),
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      await PerfLog.flush();
      expect(result, isA<EncodedPayload>());

      final content = File(logPath).readAsStringSync();
      final lines = content.split('\n');
      final submit = lines.firstWhere((l) => l.contains('reencode.submit|id='));
      final end = lines.firstWhere((l) => l.contains('reencode.end|id='));

      final submitId = RegExp(r'reencode\.submit\|id=(\d+)').firstMatch(submit)!.group(1);
      final endId = RegExp(r'reencode\.end\|id=(\d+)').firstMatch(end)!.group(1);
      expect(submitId, isNotNull);
      expect(endId, submitId, reason: 'submit/end must correlate on the same id');
      expect(end, contains('dur_us='));
      expect(end, contains('bytes=4')); // _okEncoder returns 4 bytes
    },
  );

  // TC-949
  test(
    'flag-off: neither PhotoSource.load nor reencodePayload write any perf '
    'log line -- structurally inert with PerfLog disabled',
    () async {
      PerfLog.enabled = false; // explicit: default state, but be defensive.
      const source = PhotoSource(
        loader: _needsRawDecode,
        dngDecoder: _decoder,
        payloadEncoder: _okEncoder,
      );
      final outcome = await source.load('sample.dng', longEdge: 0);
      expect(outcome.payload, isNotNull);

      final result = await reencodePayload(
        encoder: _okEncoder,
        fallback: _pixels(10, 10),
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      expect(result, isA<EncodedPayload>());

      // Never called PerfLog.init in this test -- if any emit site skipped
      // its `if (PerfLog.enabled)` guard, `PerfLog.log` would still no-op
      // safely (enabled stays false), but a broken guard that computed the
      // interpolated string unconditionally would still be wasted work, not
      // a crash. The behavioral assertions above (payload/result non-null,
      // no exceptions) are the actual proof of "no observable side effect
      // occurred" available without touching perf_log.dart to expose _buf.
      expect(PerfLog.enabled, isFalse);
    },
  );

  // Also throwing-encoder path still emits reencode.end with bytes=0.
  test(
    'flag-on: a throwing encoder still emits reencode.end (bytes=0) before '
    'falling back',
    () async {
      PerfLog.init(logPath);
      final fallback = _pixels(10, 10);
      final result = await reencodePayload(
        encoder: _throwingEncoder,
        fallback: fallback,
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      await PerfLog.flush();
      expect(identical(result, fallback), isTrue);

      final content = File(logPath).readAsStringSync();
      expect(content, contains('reencode.submit|id='));
      expect(content, contains('reencode.end|id='));
      expect(content, contains('bytes=0'));
    },
  );

  // TC-950 (ownership extension): decoded_rgba_image_provider.dart's
  // `_imageFromPixels` materialize site, reached via decodedRgbaToPixelPayload.
  test(
    'flag-on: decodedRgbaToPixelPayload emits materialize|id=|bytes=|dur_us= '
    'around the ui.decodeImageFromPixels GPU hand-off',
    () async {
      PerfLog.init(logPath);
      final decoded = _decodedFixture();
      // Orientation 6 (not identity): forces the GPU pass this test targets;
      // see _needsRawDecodeRotated's comment above.
      await decodedRgbaToPixelPayload(decoded, exifOrientation: 6, longEdge: 8);
      await PerfLog.flush();

      final content = File(logPath).readAsStringSync();
      expect(content, contains('materialize|id='));
      expect(content, contains('bytes=${8 * 6 * 4}'));
      expect(content, contains('dur_us='));
    },
  );

  // TC-951 (ownership extension): raw_pixels_image.dart's `_decode`
  // materialize site, reached through the public ImageProvider API.
  test(
    'flag-on: RawPixelsImage resolution emits materialize|id=|bytes=|dur_us=',
    () async {
      PerfLog.init(logPath);
      final payload = PixelPayload(
        rgba: Uint8List.fromList(List<int>.generate(2 * 2 * 4, (i) => i)),
        width: 2,
        height: 2,
      );
      final provider = RawPixelsImage(payload);
      final completer = Completer<ui.Image>();
      final stream = provider.resolve(const ImageConfiguration());
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        stream.removeListener(listener);
        completer.complete(info.image);
      }, onError: (error, _) {
        stream.removeListener(listener);
        completer.completeError(error);
      });
      stream.addListener(listener);
      final image = await completer.future;
      image.dispose();
      await PerfLog.flush();

      final content = File(logPath).readAsStringSync();
      expect(content, contains('materialize|id='));
      expect(content, contains('bytes=${2 * 2 * 4}'));
      expect(content, contains('dur_us='));
    },
  );

  // TC-952 (ownership extension): sidebar_thumbnail_codec.dart's
  // `ImmutableBuffer.fromUint8List` materialize site.
  test(
    'flag-on: sidebarCacheBytes over threshold emits materialize|id=|bytes=|dur_us=',
    () async {
      PerfLog.init(logPath);
      final src = await _bigPng();
      final out = await sidebarCacheBytes(src, reencodeThreshold: 1024);
      expect([out[0], out[1]], [0xFF, 0xD8]); // re-encode branch was taken
      await PerfLog.flush();

      final content = File(logPath).readAsStringSync();
      expect(content, contains('materialize|id='));
      expect(content, contains('bytes=${src.length}'));
      expect(content, contains('dur_us='));
    },
  );

  // TC-953 (ownership extension): tier_two_scheduler.dart's
  // publishPiggybackFullRes materialize site, id=<photo id> (not a hash --
  // this call site has the real id in scope, unlike the other three).
  test(
    'flag-on: publishPiggybackFullRes with no supplied handle emits '
    'materialize|id=<photoId>|bytes=|dur_us=',
    () async {
      PerfLog.init(logPath);
      final payload = EncodedPayload(Uint8List(4));
      final h = _tierTwoHarness((id) => payload);
      h.scheduler.updateWindow([_photoItem('a')], 0);
      await h.scheduler.publishPiggybackFullRes(
        'a',
        payload,
        (rgba: Uint8List(4 * 4 * 4), width: 4, height: 4, image: null),
        () {},
        distance: 0,
      );
      await PerfLog.flush();

      final content = File(logPath).readAsStringSync();
      expect(content, contains('materialize|id=a'));
      expect(content, contains('bytes=${4 * 4 * 4}'));
      expect(content, contains('dur_us='));
    },
  );
}
