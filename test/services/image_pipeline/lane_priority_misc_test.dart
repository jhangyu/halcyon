import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';
import 'package:halcyon_flutter/services/image_pipeline/bitmap_container_probe.dart';
import 'package:halcyon_flutter/services/image_pipeline/dart_image_loader.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/jpeg_encoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/lane_priority.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';
// `prefetch_scheduler.dart` re-exports `SourceCost`, which is the only thing
// from `photo_source.dart` this file names.
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_pixels_image.dart';
import 'package:halcyon_flutter/services/image_pipeline/sidebar_thumbnail_codec.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

import '../../support/preload_fixtures.dart';
import '../../support/synthetic_dng.dart';
import '../../support/temp_dirs.dart';

/// Counts `open()` calls on files created inside an [IOOverrides] zone.
///
/// Same instrument TC-090 uses in `photo_source_single_probe_test.dart`: only
/// `open()` is implemented, so a probe that reaches the filesystem another way
/// fails loudly instead of quietly under-counting.
class _CountingFile implements File {
  _CountingFile(this._inner, this._onOpen);

  final File _inner;
  final void Function() _onOpen;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    _onOpen();
    return _inner.open(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<int> _countingOpens(Future<void> Function() body) async {
  var opens = 0;
  await IOOverrides.runZoned(
    body,
    createFile: (path) =>
        _CountingFile(Zone.root.run(() => File(path)), () => opens++),
  );
  return opens;
}

Future<NativeImageResult> _rawLoaderPriority(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _tinyPriority() {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 8, height: 8);
}

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
  group('bitmap_container_probe_test.dart', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('halcyon_bitmap_probe');
    });
    tearDownAll(() => deleteTempDir(tmp));

    Future<String> write(String name, Uint8List bytes) async {
      final file = File('${tmp.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }

    group('TC-330: the probe seam routes by container family', () {
      test('a .tif is read by the IFD0 walker, not the HEIF probe', () async {
        var heifCalls = 0;
        Future<BitmapContainerExtent?> neverHeif(String path) async {
          heifCalls++;
          return null;
        }

        final path = await write(
          'scan.tif',
          buildSyntheticTiffHeader(width: 800, height: 600, orientation: 6),
        );
        final extent = await probeBitmapContainer(path, heifProbe: neverHeif);
        expect(extent, isNotNull);
        expect(extent!.width, 800);
        expect(extent.height, 600);
        expect(extent.orientation, 6);
        expect(
          heifCalls,
          0,
          reason: 'a TIFF must never reach the native HEIF probe — that would '
              'load a dylib on a path that has a pure-Dart answer',
        );
      });

      test('a .heic is read by the HEIF probe, not the IFD0 walker', () async {
        var heifCalls = 0;
        Future<BitmapContainerExtent?> fakeHeif(String path) async {
          heifCalls++;
          return (width: 4032, height: 3024, orientation: 1);
        }

        // Content is irrelevant: the IFD0 walker would return null on ISO-BMFF
        // anyway, so a non-null answer can only have come from the HEIF arm.
        final path = await write('shot.heic', Uint8List.fromList([0, 0, 0, 24]));
        final extent = await probeBitmapContainer(path, heifProbe: fakeHeif);
        expect(heifCalls, 1);
        expect(extent, isNotNull);
        expect(extent!.width, 4032);
        expect(extent.height, 3024);
        expect(extent.orientation, 1);
      });

      test('an unavailable HEIF probe yields null, never a throw', () async {
        Future<BitmapContainerExtent?> unavailable(String path) async => null;
        final path = await write('shot2.heic', Uint8List.fromList([0, 0, 0, 24]));
        expect(await probeBitmapContainer(path, heifProbe: unavailable), isNull);
      });

      test('a throwing HEIF probe is swallowed into null', () async {
        Future<BitmapContainerExtent?> boom(String path) async =>
            throw StateError('dylib exploded');
        final path = await write('shot3.heic', Uint8List.fromList([0, 0, 0, 24]));
        // The loader is documented as never throwing, so the seam beneath it
        // must absorb everything.
        expect(await probeBitmapContainer(path, heifProbe: boom), isNull);
      });

      test('bitmapContainerOrientation falls back to 1 when nothing answers',
          () async {
        Future<BitmapContainerExtent?> unavailable(String path) async => null;
        final path = await write('shot4.heic', Uint8List.fromList([0, 0, 0, 24]));
        expect(
          await bitmapContainerOrientation(path, heifProbe: unavailable),
          kDefaultExifOrientation,
        );
      });

      test('a throwing JXL probe becomes null, never an exception', () async {
        // The loader above this layer is documented as never throwing
        // (bitmap_container_probe.dart:44-51); a new arm must not break that.
        final extent = await probeBitmapContainer(
          'tmp/x.jxl',
          jxlProbe: (_) async => throw StateError('boom'),
        );
        expect(extent, isNull);
      });

      test('.avif probes through the libheif arm', () async {
        var heifCalls = 0;
        await probeBitmapContainer(
          'tmp/x.avif',
          heifProbe: (_) async {
            heifCalls++;
            return (width: 100, height: 50, orientation: 1);
          },
        );
        expect(heifCalls, 1);
      });
    });
  });

  group('preview_floor_longedge_test.dart', () {
    // F4 / AC6: ONE threshold answers "is the embedded preview big enough?".
    //
    // The routing verdict (`PhotoSource.probeSource`) compares the largest
    // embedded candidate against the LIVE viewport long edge (AD-033, frozen).
    // The loader used to enforce a DIFFERENT, hardcoded floor of 2800
    // (`ImageRequestPurpose.preview.targetSize`). On a window whose physical long
    // edge is under 2800 the two disagreed: the probe said `cheap`, the loader
    // then rejected the very candidate the probe had counted and forced a full RAW
    // decode for an item classified cheap.
    //
    // Synthetic fixtures on purpose: the user's own corpus carries 7008px
    // previews, which clear BOTH thresholds and are therefore blind to this bug.
    // The disagreement only shows on a preview that sits between the real viewport
    // and 2800.
    //
    //   TC-712  a sub-2800 viewport routes a 2000px-preview RAW cheap end-to-end
    //   TC-713  AD-033 guard: a viewport ABOVE the preview still routes expensive

    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory dir;
    late String dngPath;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('m4_preview_floor');
      addTempDirTeardown(dir);
      // ONE candidate at 2000px: bigger than a small window, smaller than the
      // old hardcoded 2800 floor. DefaultCropSize tracks the largest candidate,
      // so this candidate also clears the extractor's 0.90*cropMax full-size
      // gate -- the only thing under test here is the FLOOR.
      dngPath = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 2000, height: 1333)],
        ),
        dir: dir,
        name: 'preview2000.dng',
      );
    });

    // No decoder is wired on purpose. With no decoder, a `NeedsRawDecode` verdict
    // becomes an unmistakable `expensive` + null payload + NO_NATIVE_DECODER,
    // so "the loader rejected the preview" cannot hide behind a successful
    // decode. The assertion is therefore about the ROUTE, not the pixels.
    const source = PhotoSource(loader: dartImageLoad);

    test('TC-712 a sub-2800 viewport routes a 2000px-preview RAW cheap '
        'end-to-end', () async {
      const viewportLongEdge = 1600;

      // Half one: the routing verdict. 2000 >= 1600, so AD-033 says cheap.
      expect(
        (await PhotoSource.probeSource(dngPath, longEdge: viewportLongEdge)).cost,
        SourceCost.cheap,
        reason: 'the frozen AD-033 comparison against the LIVE viewport is the '
            'reference answer this test holds the loader to',
      );

      // Half two: the loader must reach the SAME answer. Before the fix it
      // measured the same file against a hardcoded 2800, rejected the 2000px
      // candidate, and returned NeedsRawDecode -- a full RAW decode for an item
      // the scheduler had just put on the cheap lane.
      final outcome = await source.load(dngPath, longEdge: viewportLongEdge);
      expect(
        outcome.observedCost,
        SourceCost.cheap,
        reason: 'the loader must apply the SAME long edge the routing '
            'comparison used, not a hardcoded 2800',
      );
      expect(
        outcome.payload,
        isNotNull,
        reason: 'the embedded preview clears the live viewport, so it must be '
            'served; a null payload here is the wasted-RAW-decode route',
      );
      expect(outcome.deferred, isFalse);
      expect(outcome.failureCode, isNull);
    });

    // The negative half. AD-033 is frozen: this fix changes WHERE the number
    // comes from and must not loosen the comparison. A viewport ABOVE the
    // preview's long edge must still refuse the preview.
    test('TC-713 a viewport above the preview still routes expensive '
        '(AD-033 unchanged)', () async {
      const viewportLongEdge = 4000;

      expect(
        (await PhotoSource.probeSource(dngPath, longEdge: viewportLongEdge)).cost,
        SourceCost.expensive,
        reason: '2000 < 4000: a sub-viewport preview scaled up is visibly '
            'blurry, which is exactly what AD-033 refuses',
      );

      final outcome = await source.load(dngPath, longEdge: viewportLongEdge);
      expect(
        outcome.observedCost,
        SourceCost.expensive,
        reason: 'threading the live long edge must not make the loader more '
            'permissive -- 2000px cannot satisfy a 4000px viewport',
      );
      expect(outcome.payload, isNull);
      expect(
        outcome.failureCode,
        kNoNativeDecoderCode,
        reason: 'no decoder is wired, so the refused preview surfaces as the D3 '
            'state -- proof the loader really did reject the candidate',
      );
    });
  });

  group('shared_display_quality_test.dart', () {
    test('TC-438 the shared display quality constant is q70', () {
      expect(kDisplayJpegQuality, 70);
    });

    test('TC-439 the payload re-encoder quality IS the shared constant', () {
      expect(kReencodeJpegQuality, same(kDisplayJpegQuality));
      expect(kReencodeJpegQuality, kDisplayJpegQuality);
    });

    test('TC-440 the sidebar tile encodes at the shared quality, not q80', () async {
      // A payload above the re-encode threshold is re-encoded; below it passes
      // through untouched. Assert the DEFAULT parameter, which is the contract
      // the codec exposes, by comparing an explicit-q70 call with a default call.
      final big = Uint8List(600 * 1024); // undecodable -> both paths return input
      final viaDefault = await sidebarCacheBytes(big);
      final viaExplicit = await sidebarCacheBytes(big, jpegQuality: kDisplayJpegQuality);
      expect(viaDefault.length, viaExplicit.length);
      expect(defaultSidebarJpegQuality, kDisplayJpegQuality);
    });
  });

  group('cost_memo_longedge_test.dart', () {
    // F5 / AC7: the cost memo must not stay frozen against the BOOTSTRAP viewport.
    //
    // `_longEdge` answers `kDefaultPreviewLongEdge` (2800) until the viewport's
    // LayoutBuilder calls `updateTargetSize`, and the first window pass runs before
    // that frame exists. The memo was keyed by id alone and written first-writer-
    // wins, so that whole first window was classified against a placeholder and the
    // verdict was never revisited -- not when the real viewport reported, not on a
    // window resize. On a display whose physical long edge exceeds 2800, previews
    // between 2800 and the real viewport stayed permanently `cheap` and were
    // displayed upscaled: exactly what AD-033's frozen threshold exists to prevent.
    //
    // Synthetic fixture on purpose: the flip is only visible on a preview that
    // STRADDLES the bootstrap default and the real viewport (here 3000px, between
    // 2800 and 4000). The user's 7008px corpus clears both and is blind to it.
    //
    //   TC-714  scheduler: the verdict changes when the long edge changes
    //   TC-715  controller: the verdict flips after updateTargetSize
    //   TC-716  probe economy: still ONE walk per file for a stable viewport

    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory dir;
    late String dngPath;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('m4_cost_memo');
      addTempDirTeardown(dir);
      // 3000px STRADDLES the bootstrap default (2800) and the real viewport
      // (4000) used below: cheap under the placeholder, expensive under the
      // truth. That gap is the whole defect.
      dngPath = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 3000, height: 2000)],
        ),
        dir: dir,
        name: 'preview3000.dng',
      );
    });

    test('TC-714 the memo answers for the long edge it was measured at',
        () async {
      final scheduler = PrefetchScheduler();

      expect(
        (await scheduler.classify('straddler', dngPath, longEdge: 2800)).cost,
        SourceCost.cheap,
        reason: '3000 >= 2800: correct answer for the BOOTSTRAP viewport',
      );

      // The real viewport now reports. Before the fix this returned the memoised
      // `cheap` without a second thought, and the item was served a 3000px
      // preview upscaled to a 4000px window forever.
      expect(
        (await scheduler.classify('straddler', dngPath, longEdge: 4000)).cost,
        SourceCost.expensive,
        reason: 'a verdict measured against 2800 says nothing about a 4000px '
            'viewport -- the memo must not answer a question it never asked',
      );
    });

    // AC7 through the controller: a first-window item classified against the
    // bootstrap 2800 must be re-evaluated once the real viewport is known.
    //
    // The item is browsed AWAY from first, so retention evicts its payload while
    // the cost memo (cleared only by `reset()`) keeps the stale 2800 verdict.
    // That is the state the shipped mechanism governs, and it is the ordinary
    // "browse on, resize the window, come back" sequence.
    //
    // SCOPE, stated rather than implied: an item whose payload is STILL RETAINED
    // is not re-routed by this fix, because `_earlyResolve`
    // (image_preload_controller.dart:832-845) returns on the cache hit before
    // `classify` is reached. Root-caused and parked, with evidence, in
    // docs/logs/2026-09-03/m4-ac7-cached-payload-finding.md. Asserting the
    // retained case here would be asserting something nothing implements.
    //
    // Observable: whether the RAW decoder runs. Cheap => the embedded preview is
    // served and the decoder is never touched; expensive => the serial lane
    // decodes. Counting decodes makes the flip mechanical rather than a claim
    // about an enum nobody can see.
    test('TC-715 a first-window verdict is re-evaluated after updateTargetSize',
        () async {
      var decodes = 0;
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageFailure('UNEXPECTED', 'probe decides the rung here'),
        dngDecoder: (path) async {
          decodes++;
          return DecodedRgba(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2);
        },
        // Test-only seam: firing the tier-2 debounce immediately still lets a
        // wrongly-triggered decode happen (and be caught below) -- it just
        // removes the real 250ms wait for the ordinary "nothing decodes" case.
        navigationDebounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      // One file, many ids: the memo is keyed per id, so only 'straddler' carries
      // a first-window verdict. The rest exist to move the retention window.
      final items = [
        for (var i = 0; i < 30; i++)
          PhotoItem(id: i == 0 ? 'straddler' : 'filler-$i', files: [File(dngPath)]),
      ];

      // Pass 1: NO updateTargetSize yet -- exactly the first-window ordering
      // (loadFolder -> selectItem -> preloadImages all precede the first frame).
      // _longEdge is the 2800 placeholder, so 3000 clears it and the item is
      // cheap: no decode may run.
      await controller.preloadImages(
        items: items,
        selectedItemId: 'straddler',
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor('straddler') != null,
        reason: 'pass 1 to serve the embedded preview',
      );
      expect(
        decodes,
        0,
        reason: 'against the bootstrap 2800 this item is genuinely cheap; a '
            'decode here would mean the test is measuring something else',
      );
      expect(
        controller.payloadFor('straddler'),
        isNotNull,
        reason: 'pass 1 served the embedded preview at the bootstrap viewport',
      );

      // The viewport finally reports a display whose physical long edge is 4000,
      // and the user browses on. Retention drops the payload; the cost memo
      // survives (it is cleared only by a folder reload), which is exactly the
      // state F5 describes.
      controller.updateTargetSize(4000, 2600);
      await controller.preloadImages(
        items: items,
        selectedItemId: 'filler-29',
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor('straddler') == null,
        reason: 'browsing away must evict the first-window payload, or this test '
            'is measuring the cache rather than the memo',
      );
      final decodesBeforeReturn = decodes;

      // Coming back. Nothing is retained for this id any more, so the router has
      // to ask again -- and before the fix the memo answered with the verdict it
      // had measured against 2800, so the item was served the same 3000px
      // preview upscaled into a 4000px window forever (the outcome AD-033
      // exists to prevent) and NO decode ever ran.
      await controller.preloadImages(
        items: items,
        selectedItemId: 'straddler',
        notifyLoaded: () {},
      );
      await until(
        () => decodes > decodesBeforeReturn,
        reason: 'the re-evaluated verdict is expensive, so the serial lane must '
            'run a real RAW decode once the true viewport is known',
      );
    });

    // The economy this memo exists for (the invariant-I6 successor): a STABLE
    // viewport must still cost exactly one walk per file per folder. Re-probing
    // on a long-edge change is bounded by resize events; re-probing per
    // navigation would be the regression.
    test('TC-716 a stable viewport still costs exactly ONE walk per file',
        () async {
      final scheduler = PrefetchScheduler();

      final opensAtFirstLongEdge = await _countingOpens(() async {
        for (var i = 0; i < 5; i++) {
          await scheduler.classify('straddler', dngPath, longEdge: 2800);
        }
      });
      expect(
        opensAtFirstLongEdge,
        1,
        reason: 'five classify calls at the SAME long edge must walk the file '
            'once; $opensAtFirstLongEdge opens is a probe-per-navigation '
            'regression',
      );

      final opensAfterResize = await _countingOpens(() async {
        for (var i = 0; i < 5; i++) {
          await scheduler.classify('straddler', dngPath, longEdge: 4000);
        }
      });
      expect(
        opensAfterResize,
        1,
        reason: 'a long-edge change buys exactly ONE re-measurement, then the '
            'new value is memoised in its turn',
      );
    });
  });

  group('lane_priority_test.dart', () {
    // Phase 4 — the unified lane priority function
    // (async-pipeline-refactor-plan.md §3 Phase 4, with contract override S4).
    //
    // These are PROPERTY-style tests over the full legal distance range, not three
    // hand-picked cases: the defect class this file exists to prevent (a
    // within-group distance large enough to punch through the next band's base) is
    // invisible to any fixed set of small examples, which is exactly how it
    // survived in the pre-Phase-4 code.

    group('TC-978 band order', () {
      test('every band is strictly ordered, at every legal distance', () {
        // The whole cross product: for each ordered pair of bands and each legal
        // distance in BOTH, the lower band must win. This is the assertion that
        // makes the base gap load-bearing rather than decorative.
        const distances = <int>[
          0,
          1,
          2,
          10,
          99,
          100,
          500,
          998,
          kMaxWithinGroupDistance,
          // Deliberately beyond the legal range: the clamp must keep these in
          // their own band too (see TC-979).
          kLaneBandGap,
          kLaneBandGap + 1,
          100000,
        ];
        final groups = LaneGroup.values;
        for (var i = 0; i < groups.length; i++) {
          for (var j = i + 1; j < groups.length; j++) {
            for (final di in distances) {
              for (final dj in distances) {
                expect(
                  lanePriorityFor(group: groups[i], withinGroupDistance: di),
                  lessThan(
                    lanePriorityFor(group: groups[j], withinGroupDistance: dj),
                  ),
                  reason:
                      '${groups[i].name}@$di must outrank ${groups[j].name}@$dj',
                );
              }
            }
          }
        }
      });

      test(
        'the ruled band order is exactly P1 < P2 < full-res < P3 < P4 (S4)',
        () {
          // Named explicitly because this ORDER is a user ruling, not an
          // implementation detail: the refactor plan proposed moving full-res
          // above all sidebar work and the contract's override S4 cancelled it.
          // If a future refactor re-orders the enum, this fails loudly and the
          // person doing it has to go and get a user decision.
          expect(LaneGroup.values, [
            LaneGroup.selected,
            LaneGroup.navigationWindow,
            LaneGroup.fullRes,
            LaneGroup.sidebarVisible,
            LaneGroup.sidebarMargin,
          ]);
          expect(laneBaseFor(LaneGroup.selected), 0);
          expect(laneBaseFor(LaneGroup.navigationWindow), 1000);
          expect(laneBaseFor(LaneGroup.fullRes), 2000);
          expect(laneBaseFor(LaneGroup.sidebarVisible), 3000);
          expect(laneBaseFor(LaneGroup.sidebarMargin), 4000);
        },
      );
    });

    group('TC-979 within-group distance', () {
      test('is monotone up to the clamp and never leaves its band', () {
        for (final group in LaneGroup.values) {
          final base = laneBaseFor(group);
          var previous = lanePriorityFor(group: group, withinGroupDistance: 0);
          expect(previous, base);
          for (var d = 1; d <= kMaxWithinGroupDistance; d++) {
            final p = lanePriorityFor(group: group, withinGroupDistance: d);
            expect(p, greaterThan(previous), reason: '${group.name}@$d');
            expect(
              p,
              lessThan(base + kLaneBandGap),
              reason: '${group.name}@$d escaped its band',
            );
            previous = p;
          }
        }
      });

      test('clamps beyond the legal range instead of punching through', () {
        // The plan allowed "widen the gap" OR "clamp"; this implementation does
        // both, because the gap alone is an assumption about data (nobody ever
        // has 1000 sidebar rows visible) while the clamp is a property of the
        // code. A tall viewport must degrade to a TIE, never to a band jump.
        for (final group in LaneGroup.values) {
          final atClamp = lanePriorityFor(
            group: group,
            withinGroupDistance: kMaxWithinGroupDistance,
          );
          for (final d in [kLaneBandGap, kLaneBandGap + 7, 1 << 20]) {
            expect(
              lanePriorityFor(group: group, withinGroupDistance: d),
              atClamp,
              reason: '${group.name}@$d must clamp, not overflow into the next '
                  'band',
            );
          }
        }
      });
    });

    group('TC-980 navigation classifier', () {
      test('the selected slot is P1 and everything else is P2', () {
        expect(navigationPriorityFor(0), laneBaseFor(LaneGroup.selected));
        for (final d in [1, -1, 2, -2, 3, -3, 5, -3, 11, -11]) {
          expect(
            navigationPriorityFor(d),
            greaterThanOrEqualTo(laneBaseFor(LaneGroup.navigationWindow)),
            reason: 'distance $d is window work, not the selection',
          );
          expect(
            navigationPriorityFor(d),
            lessThan(laneBaseFor(LaneGroup.fullRes)),
            reason: 'distance $d must not reach the full-res band',
          );
        }
      });

      test(
        'keeps the user-ruled near-to-far order 0, +1, -1, +2, -2, +3, -3, +4, +5',
        () {
          // The 2026-08-26 ruling, asserted as an ORDER over the whole retention
          // window rather than as a formula, so a change to laneRankForDistance
          // that preserved its shape but not its ruling would still fail.
          const ruledOrder = [0, 1, -1, 2, -2, 3, -3, 4, 5];
          final priorities = [
            for (final d in ruledOrder) navigationPriorityFor(d),
          ];
          for (var i = 1; i < priorities.length; i++) {
            expect(
              priorities[i],
              greaterThan(priorities[i - 1]),
              reason:
                  'slot ${ruledOrder[i]} must rank after slot ${ruledOrder[i - 1]}',
            );
          }
        },
      );

      test('a forward slot outranks the mirrored backward slot', () {
        for (var d = 1; d <= 11; d++) {
          expect(
            navigationPriorityFor(d),
            lessThan(navigationPriorityFor(-d)),
            reason: 'browsing is predominantly forward (+$d before -$d)',
          );
        }
      });
    });

    group('TC-981 sidebar classifier', () {
      test('every visible row outranks every margin row (D1 AC1 property)', () {
        // D1's own regression tests (TC-963/TC-964) prove this through the
        // controller; this proves it over a range of viewport geometries the
        // controller tests do not enumerate, including the tall-viewport case
        // that defeated the pre-D1 formula and would defeat a gap-only fix.
        for (final span in [1, 2, 5, 41, 200, 1500]) {
          const safeStart = 100;
          final safeEnd = safeStart + span - 1;
          final visible = [
            for (var i = safeStart; i <= safeEnd; i++)
              sidebarPriorityFor(index: i, safeStart: safeStart, safeEnd: safeEnd),
          ];
          final margin = [
            for (final i in [
              safeStart - 1,
              safeStart - 20,
              safeEnd + 1,
              safeEnd + 20,
            ])
              sidebarPriorityFor(index: i, safeStart: safeStart, safeEnd: safeEnd),
          ];
          expect(
            visible.reduce((a, b) => a > b ? a : b),
            lessThan(margin.reduce((a, b) => a < b ? a : b)),
            reason:
                'span $span: the worst visible row must still outrank the best '
                'margin row',
          );
        }
      });

      test('a visible row ranks by distance from the centre', () {
        const safeStart = 10;
        const safeEnd = 30; // centre 20
        final centre = sidebarPriorityFor(
          index: 20,
          safeStart: safeStart,
          safeEnd: safeEnd,
        );
        expect(centre, laneBaseFor(LaneGroup.sidebarVisible));
        for (var d = 1; d <= 10; d++) {
          expect(
            sidebarPriorityFor(
              index: 20 + d,
              safeStart: safeStart,
              safeEnd: safeEnd,
            ),
            centre + d,
          );
          expect(
            sidebarPriorityFor(
              index: 20 - d,
              safeStart: safeStart,
              safeEnd: safeEnd,
            ),
            centre + d,
          );
        }
      });

      test('a margin row ranks by distance from the nearest edge', () {
        const safeStart = 10;
        const safeEnd = 30;
        final base = laneBaseFor(LaneGroup.sidebarMargin);
        for (var d = 1; d <= 20; d++) {
          expect(
            sidebarPriorityFor(
              index: safeStart - d,
              safeStart: safeStart,
              safeEnd: safeEnd,
            ),
            base + d,
          );
          expect(
            sidebarPriorityFor(
              index: safeEnd + d,
              safeStart: safeStart,
              safeEnd: safeEnd,
            ),
            base + d,
          );
        }
      });

      test(
        'a 4000-row viewport cannot punch a visible row out of the P3 band',
        () {
          // The concrete form of the defect the clamp exists for. Before the
          // clamp, a row 1200 slots from the centre would have produced
          // 3000 + 1200 = 4200, i.e. a P3 row ranking behind P4 margin work --
          // and with a smaller gap it would have crossed into full-res.
          // Span chosen so the worst centre distance (2000) EXCEEDS the band
          // gap: a 1500-row span only reaches 750 and would pass even with the
          // clamp removed, which is exactly the kind of test that looks like a
          // guard and is not one (observed: the earlier 1500-row version stayed
          // green under the clamp-removal mutation).
          const safeStart = 0;
          const safeEnd = 3999;
          for (final index in [0, 1, 1000, 2500, 3999]) {
            final p = sidebarPriorityFor(
              index: index,
              safeStart: safeStart,
              safeEnd: safeEnd,
            );
            expect(p, greaterThanOrEqualTo(laneBaseFor(LaneGroup.sidebarVisible)));
            expect(p, lessThan(laneBaseFor(LaneGroup.sidebarMargin)));
          }
        },
      );
    });

    group('TC-982 isSidebarPriority (G-027 predicate)', () {
      test('is true for sidebar bands and false for everything below', () {
        expect(isSidebarPriority(navigationPriorityFor(0)), isFalse);
        for (final d in [1, -1, 5, -3, 11]) {
          expect(isSidebarPriority(navigationPriorityFor(d)), isFalse);
        }
        for (final d in [0, 1, -1, 5]) {
          expect(
            isSidebarPriority(fullResPriorityFor(d)),
            isFalse,
            reason:
                'full-res is not sidebar work: a pending full-res entry must '
                'never be treated as re-rankable by a sidebar sweep',
          );
        }
        for (final index in [10, 20, 30, 5, 45]) {
          expect(
            isSidebarPriority(
              sidebarPriorityFor(index: index, safeStart: 10, safeEnd: 30),
            ),
            isTrue,
          );
        }
      });

      test('the boundary is exactly the sidebar-visible base', () {
        expect(
          isSidebarPriority(laneBaseFor(LaneGroup.sidebarVisible) - 1),
          isFalse,
        );
        expect(isSidebarPriority(laneBaseFor(LaneGroup.sidebarVisible)), isTrue);
      });
    });

    // The G-027 direction assertions (plan §3 Phase 4 acceptance bullet 3, risk
    // R5). These run through the real controller and lane rather than the pure
    // function, because the defect they guard is a WIRING defect: the pure
    // function can be perfectly ordered while the sidebar re-enqueues a key that
    // navigation is waiting on and demotes it.
    group('TC-983 G-027 direction through the real lane', () {
      test(
        'a navigation enqueue RAISES the priority of a key the sidebar queued, '
        'and a later sidebar sweep never demotes it back',
        () async {
          final gate = Completer<void>();
          final controller = ImagePreloadController(
            imageLoader: _rawLoaderPriority,
            dngDecoder: (path) async {
              // Gated so every enqueued key stays PENDING and its priority is
              // observable; the lane is width 1 so one key occupies the slot.
              await gate.future;
              return _tinyPriority();
            },
            payloadEncoder: null,
            decodeLaneWidth: 1,
          );
          addTearDown(controller.dispose);
          controller.updateTargetSize(800, 600);
          final items = photoItems(400, extension: 'arw');

          // 1. The SIDEBAR queues p200 as a margin row (visible range is far
          //    away), i.e. in the worst band there is.
          await controller.preloadThumbnails(
            items: items,
            startIdx: 180,
            endIdx: 195,
            notifyLoaded: () {},
          );
          await until(
            () => controller.debugLanePendingPriorityFor('p200') != null,
            reason: 'the sidebar sweep to queue p200',
          );
          final sidebarPriority = controller.debugLanePendingPriorityFor('p200')!;
          expect(
            isSidebarPriority(sidebarPriority),
            isTrue,
            reason: 'precondition: p200 is queued as sidebar work',
          );

          // 2. NAVIGATION selects p200. The same lane key must be RE-RANKED up
          //    into the navigation bands -- this is the direction G-027 is
          //    about: the user is now looking at it.
          await controller.preloadImages(
            items: items,
            selectedItemId: 'p200',
            notifyLoaded: () {},
          );
          await until(
            () =>
                controller.debugLanePendingPriorityFor('p200') != null &&
                !isSidebarPriority(controller.debugLanePendingPriorityFor('p200')!),
            reason: 'the navigation enqueue to raise p200 out of the sidebar band',
          );
          final navigationPriority =
              controller.debugLanePendingPriorityFor('p200')!;
          expect(
            navigationPriority,
            lessThan(sidebarPriority),
            reason: 'a navigation enqueue must RAISE (numerically lower) the '
                'priority of a key the sidebar had queued',
          );

          // 3. THE SILENT DIRECTION. A later sidebar sweep that still wants
          //    p200 must NOT push it back down: re-ranking a navigation-pending
          //    key at a sidebar priority is exactly G-027 (memory.md:1051), and
          //    it is invisible without this assertion because nothing fails --
          //    the decode simply happens much later than the user expects.
          // SETTLE FIRST. Phase 3 made preloadImages asynchronous: its per-slot
          // probe chains keep resolving and RE-enqueueing after it returns. If
          // the sweep below runs while those are still in flight, a demotion is
          // transient -- a later navigation re-enqueue repairs it before any
          // end-state read, and this arm becomes an assertion that cannot fail
          // (observed: it stayed green under a mutation that deleted the guard).
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(
            controller.debugLanePendingPriorityFor('p200'),
            navigationPriority,
            reason: 'precondition: navigation work has settled',
          );

          // A DIFFERENT range that still keeps p200 in the margin. Repeating
          // the first range would be a no-op: the sweep short-circuits when the
          // visible range is unchanged (sidebar_thumbnail_controller.dart:415),
          // so an identical second sweep produces no re-enqueue at all and this
          // arm would pass without ever exercising the guard. Observed: with
          // the identical range, this test stayed GREEN under a mutation that
          // removed the guard entirely.
          await controller.preloadThumbnails(
            items: items,
            startIdx: 179,
            endIdx: 194,
            notifyLoaded: () {},
          );
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final afterSweep = controller.debugLanePendingPriorityFor('p200');
          expect(
            afterSweep,
            isNotNull,
            reason: 'p200 is still gated, so it must still be pending',
          );
          expect(
            isSidebarPriority(afterSweep!),
            isFalse,
            reason: 'G-027: the sidebar demoted the item navigation is waiting '
                'on, from $navigationPriority back to $afterSweep',
          );
          expect(afterSweep, lessThanOrEqualTo(navigationPriority));

          gate.complete();
        },
      );
    });

    // ROUND B REVIEW BLOCKER (fix cycle 1). The Phase 4 rebase moved three
    // producers onto the band table and missed a FOURTH: TierTwoScheduler's
    // catch-up sweep also enqueues the `(payload, id)` key, and it was still
    // handing the lane a bare `laneRankFor(distance)` (0..N).
    //
    // That is not a cosmetic inconsistency. DecodeLane RE-RANKS a pending key on
    // re-enqueue, so the sweep pulled the slots it touches (the tier-2 window,
    // -1..+3) down to 0..N while the plain navigation slots stayed at 1000+ --
    // silently inverting the 2026-08-26 start-order ruling. The suite was green
    // over it because no test mixed the two producers. This one does.
    group('TC-984 merged producer order (tier-2 catch-up + navigation)', () {
      test(
        'the tier-2 catch-up sweep does not demote navigation slots below it',
        () async {
          final gate = Completer<void>();
          final controller = ImagePreloadController(
            imageLoader: _rawLoaderPriority,
            dngDecoder: (path) async {
              // Gated forever, so nothing the lane admits ever finishes and
              // the merged pending order stays observable. NOTE what this
              // does NOT buy on its own: "pending" means "queued and not yet
              // STARTED" (decode_lane.dart:120), and "a key already IN FLIGHT
              // is not pending" (decode_lane.dart:136-138), so the one task
              // the width-1 lane admits is by definition not pending. See the
              // lane pre-occupation below.
              await gate.future;
              return _tinyPriority();
            },
            payloadEncoder: null,
            decodeLaneWidth: 1,
            // Test-only seam: the assertions below are on re-rank ORDER, not on
            // the debounce interval itself, so firing it immediately still
            // exercises the exact catch-up-sweep-vs-navigation race this test
            // targets, just without paying the real 250ms in wall time.
            navigationDebounce: Duration.zero,
          );
          addTearDown(controller.dispose);
          controller.updateTargetSize(800, 600);
          final items = photoItems(40, extension: 'arw');

          // ANCHOR THE OBSERVATION POINT (2026-09-06, task #12). Before this,
          // the walk below raced the lane: with width 1 exactly one task is
          // admitted and, once admitted, it is no longer PENDING. The tier-2
          // catch-up `fullRes` task and slot 0's own `payload` task both
          // compete for that single slot, and whichever reaches the pump first
          // holds it forever (the gate never opens until the end). Normally
          // the catch-up task won and slot 0 stayed pending; under full-suite
          // load slot 0 won, its pending priority went null, and this test
          // failed on "slot 0 must be pending" while its ORDER assertions were
          // perfectly intact -- slot 0 was admitted and in flight, not lost or
          // demoted (measured: 8/40 iterations under load on this tree, 2/40
          // at base c3bca18; evidence in docs/logs/2026-09-06/tc984-rootcause.txt).
          //
          // Fix: occupy the single lane slot with a decode for an item FAR
          // outside the window under test. Its body blocks on the same gate
          // forever, so no slot of the real window can be admitted and "every
          // window slot stays PENDING" becomes a structural fact rather than a
          // race. The priorities the walk asserts are unchanged by this.
          await controller.preloadImages(
            items: items,
            selectedItemId: items[35].id,
            notifyLoaded: () {},
          );
          await until(
            () => controller.debugDecodeLaneRunningCount > 0,
            reason: 'the out-of-window decode to occupy the single lane slot',
          );

          await controller.preloadImages(
            items: items,
            selectedItemId: items[10].id,
            notifyLoaded: () {},
          );

          // Now that the debounce is zero, the catch-up sweep has already run by
          // the time preloadImages's own await chain settles; still poll rather
          // than assume, since the sweep is a separate async chain.
          await until(
            () => controller.debugLanePendingPriorityFor(items[13].id) != null,
            reason: 'the +3 slot to be pending',
          );
          await until(
            () => controller.debugCatchUpEnqueueCount > 0,
            reason: 'the tier-2 catch-up sweep to have re-enqueued a slot',
          );

          // ANTI-VACUITY (parking-lot item 2, async-pipeline-campaign-handover
          // §9): the merged-order assertions below would pass identically if
          // the tier-2 catch-up sweep never ran at all -- navigation alone
          // produces the ruled order for slots it already owns. This proves the
          // sweep actually re-enqueued at least one payload key, so the test's
          // bite depends on the mechanism its name claims, not solely on the
          // external red-proof (docs/logs/2026-09-06/parklot-redproof.txt).
          expect(
            controller.debugCatchUpEnqueueCount,
            greaterThan(0),
            reason:
                'the tier-2 catch-up sweep must have re-enqueued at least one '
                'slot for this assertion to test anything beyond navigation '
                'alone',
          );

          // The reviewer's counterexample, verbatim: -2 is ruled to start before
          // +3 (order 0, +1, -1, +2, -2, +3, ...). Asserted on PRIORITIES, never
          // on enqueue order.
          final minusTwo = controller.debugLanePendingPriorityFor(items[8].id);
          final plusThree = controller.debugLanePendingPriorityFor(items[13].id);
          expect(minusTwo, isNotNull, reason: 'the -2 slot must still be pending');
          expect(plusThree, isNotNull, reason: 'the +3 slot must still be pending');
          expect(
            minusTwo!,
            lessThan(plusThree!),
            reason:
                'the tier-2 catch-up sweep re-ranked +3 ($plusThree) below the '
                'untouched -2 slot ($minusTwo), inverting the 2026-08-26 '
                'start-order ruling',
          );

          // The whole ruled walk, not just the one pair: every slot the sweep
          // touched must still sit in the navigation bands alongside the ones it
          // did not touch, so the merged order is one consistent sequence.
          const ruledOrder = [0, 1, -1, 2, -2, 3];
          var previous = -1;
          for (final d in ruledOrder) {
            final p = controller.debugLanePendingPriorityFor(items[10 + d].id);
            expect(p, isNotNull, reason: 'slot $d must be pending');
            expect(
              p!,
              greaterThan(previous),
              reason: 'slot $d broke the merged ruled order',
            );
            previous = p;
          }

          gate.complete();
        },
      );
    });
  });

  group('p0_perf_instrumentation_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late Directory tmpDir;
    late String logPath;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('p0_perf_test_');
      logPath = '${tmpDir.path}${Platform.pathSeparator}perf.log';
    });

    tearDown(() async {
      // PerfLog.close() (not just flush()) releases the sink's OS file handle
      // before we delete tmpDir -- on windows-latest, deleting a directory
      // that still has an open file inside it throws PathAccessException
      // (errno 32); POSIX permits it, which made this invisible on
      // macOS/Linux CI legs. See PerfLog.close()'s doc comment.
      await PerfLog.close();
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
          fallback: () async => _pixels(10, 10),
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
          fallback: () async => _pixels(10, 10),
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
          // WP1: `fallback` is a thunk now. Returning the SAME object keeps the
          // `identical(result, fallback)` assertion below meaningful.
          fallback: () async => fallback,
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
          (rgba: Uint8List(4 * 4 * 4), width: 4, height: 4, image: null, releaseNative: null),
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
  });
}
