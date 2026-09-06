import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

/// T2 (docs/logs/2026-09-06/h1h2-plan.md, spec §1.6/§3 AC-H1-2): independent
/// red->green proof that [PhotoSource.decodePhase] /
/// [PhotoSource.decodePhaseExpensive] materialize the decoded RGBA buffer
/// into a `ui.Image` EXACTLY ONCE per decode, for a non-identity EXIF
/// orientation (orientation 6 forces the GPU pass -- see
/// p0_perf_instrumentation_test.dart's `_needsRawDecodeRotated` convention).
///
/// Observation seam: `PerfLog.testSink` (lib/perf/perf_log.dart:245),
/// deliberately NOT `debugPrint` capture (lessons-learned 2026-08-17:
/// debugPrint is process-wide and order-dependent across the suite).
/// `testSink` fires BEFORE the `PerfLog.enabled` gate, so no file I/O or
/// `PerfLog.init` is needed to observe emitted lines.
///
/// TC-998 (grepped for collision against the whole tree, incl. untracked,
/// at paste time -- highest prior in docs/sop/unit_test.md was TC-997).
///
/// PRE-REGISTRATION / expected RED (before T1 landed): the pre-change
/// `decodePhase`/`decodePhaseExpensive` body called BOTH
/// `decodedRgbaToOrientedFullRes` AND `decodedRgbaToPixelPayload` on the same
/// `decoded` buffer for a non-identity orientation -- two separate
/// `_imageFromPixels` calls, hence two `materialize|` events with two
/// DIFFERENT `id=` values (id = `identityHashCode(decoded.rgba)`, which is
/// stable across both calls since it is the SAME buffer -- so the red
/// signature is "two events, same id", not "two different ids"). The fixed
/// shape derives the window payload from the already-materialized oriented
/// image via `pixelPayloadFromOrientedImage`, which performs zero additional
/// `_imageFromPixels` calls -- so exactly one `materialize|` event should
/// appear post-fix.
///
/// TIMELINE NOTE: T1 landed mid-round, in this shared tree, before this
/// file's tests could be run against a genuinely pre-T1 state -- both
/// twinned call sites (`decodePhase` and `decodePhaseExpensive`) were
/// already committed (commit `c10e9c5`) by the time this test harness was
/// correctly wired (an earlier harness bug -- `PerfLog.testSink` alone does
/// not bypass the emit sites' own `if (PerfLog.enabled)` guard -- produced a
/// false "0 events" reading first; fixed by also setting
/// `PerfLog.enabled = true`, still with no `PerfLog.init()` call so no file
/// I/O is introduced). Both tests are GREEN against this tree from the
/// first correctly-wired run.
///
/// Per "do not fabricate red evidence": RED was NOT invented by mutating
/// this test. Instead, the actual pre-T1 commit (`0b08152`, T1's parent) was
/// materialized read-only via `git show 0b08152:<path>`, `cp`-swapped into
/// place (never `git checkout --`/`stash`/`reset`, per the shared-tree red
/// lines), the suite run, and the swap `cp`-restored from a backup
/// immediately after -- `git status --porcelain` confirmed a clean restore
/// (byte-identical `diff -q` against the pre-swap backup) before this file
/// was finalized. Both TC-998 and TC-998b went RED exactly as predicted:
/// two `materialize|` events sharing the same `id=` (the SAME
/// `decoded.rgba` buffer materialized twice). Full run, with the
/// prediction written above the output, filed at
/// `docs/logs/2026-09-06/t2-redproof-single-materialize.txt`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final collected = <String>[];

  setUp(() {
    collected.clear();
    PerfLog.testSink = collected.add;
    // Emit call sites gate on `PerfLog.enabled` themselves (e.g.
    // decoded_rgba_image_provider.dart's `if (PerfLog.enabled) { PerfLog.log(...) }`
    // around the materialize event) -- `testSink` alone does not bypass that
    // gate, only PerfLog.log()'s own file-write path. `enabled = true` with
    // no `PerfLog.init()` call means no file/timer is ever created (init()
    // is the only thing that opens the sink), so this stays structurally
    // free of file I/O; testSink is still what this test asserts against.
    PerfLog.enabled = true;
  });

  tearDown(() {
    PerfLog.testSink = null;
    PerfLog.enabled = false;
  });

  /// 8x6 opaque RGBA, matching the convention in
  /// photo_source_fullres_handle_test.dart / p0_perf_instrumentation_test.dart.
  DecodedRgba decodedFixture() {
    final bytes = Uint8List(8 * 6 * 4);
    for (var p = 0; p < 8 * 6; p++) {
      bytes[p * 4 + 3] = 255;
    }
    return DecodedRgba(rgba: bytes, width: 8, height: 6);
  }

  List<String> materializeEvents() =>
      collected.where((l) => l.startsWith('materialize|')).toList();

  List<String> materializeIds(List<String> events) => events
      .map((l) => RegExp(r'id=(-?\d+)').firstMatch(l)!.group(1)!)
      .toList();

  // TC-998
  test(
    'decodePhase: non-identity orientation materializes the decoded buffer '
    'exactly once (single materialize|, no repeated id)',
    () async {
      lastDecodedFixture = decodedFixture();
      const source = PhotoSource(
        loader: _needsRawDecodeOrientation6,
        dngDecoder: _fixtureDecoder,
      );

      final decode = await source.decodePhase('sample.dng', longEdge: 0);

      expect(decode.pixels, isNotNull);
      expect(decode.fullRes, isNotNull);
      decode.fullRes!.image?.dispose();

      final events = materializeEvents();
      expect(
        events,
        hasLength(1),
        reason:
            'expected exactly one materialize| event for one decode; got '
            '${events.length}: $events',
      );
      final ids = materializeIds(events);
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason: 'no id= value may repeat across materialize| events',
      );
    },
  );

  // TC-998b (twin assertion for decodePhaseExpensive, per plan T2 step 3)
  test(
    'decodePhaseExpensive: non-identity orientation materializes the '
    'decoded buffer exactly once (single materialize|, no repeated id)',
    () async {
      lastDecodedFixture = decodedFixture();
      const source = PhotoSource(
        loader: _unusedLoader,
        dngDecoder: _fixtureDecoder,
      );

      final decode = await source.decodePhaseExpensive(
        'sample.dng',
        longEdge: 0,
        exifOrientation: 6,
      );

      expect(decode.pixels, isNotNull);
      expect(decode.fullRes, isNotNull);
      decode.fullRes!.image?.dispose();

      final events = materializeEvents();
      expect(
        events,
        hasLength(1),
        reason:
            'expected exactly one materialize| event for one decode; got '
            '${events.length}: $events',
      );
      final ids = materializeIds(events);
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason: 'no id= value may repeat across materialize| events',
      );
    },
  );
}

Future<NativeImageResult> _unusedLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => throw StateError('decodePhaseExpensive must not call loader');

Future<NativeImageResult> _needsRawDecodeOrientation6(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

/// Set immediately before each `PhotoSource` call in this file -- `const`
/// `PhotoSource` construction requires top-level function references, so the
/// fixture itself is threaded through this mutable top-level instead of a
/// closure.
late DecodedRgba lastDecodedFixture;

Future<DecodedRgba> _fixtureDecoder(String path) async => lastDecodedFixture;
