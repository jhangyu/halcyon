import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';

import '../../support/flaky_io.dart';
import '../../support/synthetic_dng.dart';

/// TC-717 — a TRANSIENT read failure must not be reported as "no embedded
/// preview".
///
/// Root cause (docs/logs/2026-09-02/h1-pipeline-race-findings.md, refined by
/// h2's measurements in repro-experiment.md §3): every read path in the
/// extractor degraded an I/O fault to the same `null` a genuinely preview-less
/// container produces — `_readDirect`'s `if (bytes.length != count) return
/// null` and its `catch`. The selected preview strip is fetched in ONE read
/// that bypasses the page cache, so a single short return there makes the
/// walker report the container as having only unreadable previews. Upstream
/// that becomes `NativeImageNeedsRawDecode` → the serial lane → a full RAW
/// decode, and the verdict is memoised for the whole folder session
/// (`prefetch_scheduler.dart:90-99`). One hiccup therefore costs the photo its
/// embedded preview until the app is relaunched — the reported symptom.
///
/// The four cases pin both halves of the fix:
///   a/b/d — a fault is DISTINGUISHED from an absent preview, and retried;
///   c     — a genuine "no preview" answer is NOT retried, so a preview-less
///           folder does not start paying 3 opens per file.
///
/// The frozen AD-033 floor is untouched throughout: every case below passes the
/// same 2800 `minLongEdge` the production preview path uses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tc540_');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  // A container that DOES carry a preview clearing the frozen 2800 floor:
  // without an injected fault every assertion below must find it.
  Future<String> writePreviewBearingDng() async => writeSyntheticDng(
    buildSyntheticDng(
      candidates: const [SyntheticCandidate(width: 3200, height: 2133)],
    ),
    dir: dir,
    name: 'preview_bearing.dng',
  );

  Future<FaultRun<DngEmbeddedJpegProbe>> probeWithFaults(
    String path, {
    required int failFirstOpens,
    required ReadFaultShape shape,
  }) => withInjectedReadFaults(
    failFirstOpens: failFirstOpens,
    shape: shape,
    body: () => DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
      path,
      longEdge: null,
      minLongEdge: 2800,
    ),
  );

  test('control: an intact container yields its preview in exactly one open',
      () async {
    final run = await probeWithFaults(
      await writePreviewBearingDng(),
      failFirstOpens: 0,
      shape: ReadFaultShape.thrown,
    );
    expect(run.value.jpeg, isNotNull, reason: 'fixture must carry a preview');
    expect(run.opens, 1, reason: 'the happy path must stay a single open');
  });

  test('TC-717a: a THROWN read error is retried, not reported as "no preview"',
      () async {
    final run = await probeWithFaults(
      await writePreviewBearingDng(),
      failFirstOpens: 1,
      shape: ReadFaultShape.thrown,
    );
    expect(
      run.value.jpeg,
      isNotNull,
      reason: 'a transient read error must be retried, not reported as "this '
          'container has no embedded preview"',
    );
    expect(run.value.jpeg!.width, 3200);
    expect(run.opens, greaterThan(1), reason: 'the retry must re-open the file');
  });

  test('TC-717d: a SHORT read (no exception) on the preview strip is retried',
      () async {
    // The exact shape h2 measured on the user's volume: the multi-MB strip
    // comes back short, nothing throws, and the walker calls the container's
    // previews unreadable.
    final run = await probeWithFaults(
      await writePreviewBearingDng(),
      failFirstOpens: 1,
      shape: ReadFaultShape.short,
    );
    expect(
      run.value.jpeg,
      isNotNull,
      reason: 'a short read is an I/O fault, not evidence that the declared '
          'preview is unreadable',
    );
    expect(
      run.value.malformed,
      isFalse,
      reason: 'the container is intact; only the read failed',
    );
    expect(run.opens, greaterThan(1));
  });

  test('TC-717b: probeContent measurement survives a transient read failure',
      () async {
    // probeContent feeds PrefetchScheduler.classify, i.e. the cheap-vs-RAW
    // verdict memoised first-writer-wins for the whole folder. A candidate
    // whose strip read faults is skipped by the gather, which silently SHRINKS
    // this measurement — the second way a hiccup becomes a session-long RAW
    // fallback.
    final path = await writePreviewBearingDng();
    final run = await withInjectedReadFaults(
      failFirstOpens: 1,
      shape: ReadFaultShape.short,
      body: () => DngEmbeddedJpegExtractor.probeContent(path),
    );
    expect(run.value, isNotNull, reason: 'must not report "unmeasurable"');
    expect(
      run.value!.largestLongEdge,
      3200,
      reason: 'a shrunken measurement is what flips the item to the expensive '
          '(RAW decode) lane for the rest of the session',
    );
  });

  test('TC-717c: a genuinely preview-less container is NOT retried', () async {
    // The negative half. AD-033 is untouched: a 320px preview stays rejected
    // against the frozen 2800 floor, and that rejection is FINAL rather than
    // retried three times.
    final path = await writeSyntheticDng(
      buildSyntheticDng(
        candidates: const [SyntheticCandidate(width: 320, height: 213)],
      ),
      dir: dir,
      name: 'undersized.dng',
    );
    final run = await probeWithFaults(
      path,
      failFirstOpens: 0,
      shape: ReadFaultShape.thrown,
    );
    expect(run.value.jpeg, isNull);
    expect(run.opens, 1, reason: 'no I/O fault occurred, so nothing to retry');
  });
}
