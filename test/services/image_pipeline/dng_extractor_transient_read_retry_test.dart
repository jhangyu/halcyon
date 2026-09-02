import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';

import '../../support/synthetic_dng.dart';

/// TC-540 — a TRANSIENT read failure must not be latched as "no embedded
/// preview".
///
/// Root-cause context (docs/logs/2026-09-02/h1-pipeline-race-findings.md): every
/// read path in the extractor degrades an I/O error to the same `null` a
/// genuinely preview-less container produces
/// (`dng_embedded_jpeg_extractor.dart:1293-1303` and the entry-point catches).
/// Upstream that becomes `NativeImageNeedsRawDecode` -> the serial lane -> a
/// full RAW decode, and the verdict is memoised for the whole folder session
/// (`prefetch_scheduler.dart:90-99`), so ONE hiccup costs the photo its embedded
/// preview until the app is relaunched. That is the reported symptom: a random
/// subset per launch falls back to RAW rendering.
///
/// These tests pin the two halves of the fix:
///   1. a read failure is DISTINGUISHED from an absent preview, and retried;
///   2. a genuine "no preview" answer is NOT retried (the retry must not become
///      a blanket 3x cost on every preview-less RAW).
///
/// The frozen `minLongEdge` threshold (AD-033) is untouched by both: every
/// assertion below passes the same 2800 floor the production preview path uses.

/// A [RandomAccessFile] whose reads fail for the first [failOpens] opens made
/// inside the zone, then behave normally.
///
/// Models the observed failure: a transient read error on the external volume,
/// not a corrupt file. The file on disk is intact the whole time — which is
/// exactly why "retry" is a legitimate fix and not a way of papering over a
/// broken container.
class _FlakyRandomAccessFile implements RandomAccessFile {
  _FlakyRandomAccessFile(this._inner, {required this.shouldFail});

  final RandomAccessFile _inner;
  final bool shouldFail;

  Never _fail() => throw const FileSystemException(
    'simulated transient read error',
    'injected by TC-540',
    OSError('Input/output error', 5),
  );

  @override
  Uint8List readSync(int count) => shouldFail ? _fail() : _inner.readSync(count);

  @override
  Future<Uint8List> read(int count) async =>
      shouldFail ? _fail() : _inner.read(count);

  @override
  RandomAccessFile setPositionSync(int position) {
    _inner.setPositionSync(position);
    return this;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _inner.setPosition(position);
    return this;
  }

  @override
  int lengthSync() => _inner.lengthSync();

  @override
  Future<int> length() => _inner.length();

  @override
  Future<void> close() => _inner.close();

  @override
  void closeSync() => _inner.closeSync();

  @override
  String get path => _inner.path;

  // Anything else reaching this wrapper is a route the test did not anticipate;
  // failing loudly beats silently delegating and mis-attributing the result.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [RandomAccessFile] that returns SHORT reads (not exceptions) while
/// [shouldTruncate] holds.
///
/// This is the mechanism debugger-h2-opus measured on the real folder
/// (docs/logs/2026-09-02/repro-experiment.md §3): the embedded preview is
/// pulled in ONE ~8 MB `readSync`, and a short return there — no exception
/// anywhere — is indistinguishable from "this container's previews are all
/// unreadable". It is the single point of failure the fix has to cover, so it
/// gets its own case rather than being assumed equivalent to a throw.
class _ShortReadRandomAccessFile implements RandomAccessFile {
  _ShortReadRandomAccessFile(this._inner, {required this.shouldTruncate});

  final RandomAccessFile _inner;
  final bool shouldTruncate;

  @override
  Uint8List readSync(int count) {
    final bytes = _inner.readSync(count);
    if (!shouldTruncate || bytes.length < 2) return bytes;
    return Uint8List.sublistView(bytes, 0, bytes.length - 1);
  }

  @override
  Future<Uint8List> read(int count) => _inner.read(count);

  @override
  RandomAccessFile setPositionSync(int position) {
    _inner.setPositionSync(position);
    return this;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _inner.setPosition(position);
    return this;
  }

  @override
  int lengthSync() => _inner.lengthSync();

  @override
  Future<int> length() => _inner.length();

  @override
  Future<void> close() => _inner.close();

  @override
  void closeSync() => _inner.closeSync();

  @override
  String get path => _inner.path;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ShortReadFile implements File {
  _ShortReadFile(this._inner, this._onOpen);

  final File _inner;
  final bool Function() _onOpen;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _ShortReadRandomAccessFile(await _inner.open(mode: mode),
          shouldTruncate: _onOpen());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FlakyFile implements File {
  _FlakyFile(this._inner, this._onOpen);

  final File _inner;

  /// Returns true when THIS open's reads should fail.
  final bool Function() _onOpen;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _FlakyRandomAccessFile(await _inner.open(mode: mode),
          shouldFail: _onOpen());

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _FlakyRandomAccessFile(_inner.openSync(mode: mode),
          shouldFail: _onOpen());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs [body] with file opens counted, failing the reads of the first
/// [failFirstOpens] opens. Returns the total number of opens performed.
Future<int> _withFlakyReads<T>(
  int failFirstOpens,
  Future<T> Function() body,
) async {
  var opens = 0;
  await IOOverrides.runZoned(
    body,
    // Zone.root escapes this override, so the wrapped File is a real one
    // rather than an infinite regress through the factory (same pattern as
    // photo_source_single_probe_test.dart).
    createFile: (path) => _FlakyFile(
      Zone.root.run(() => File(path)),
      () => opens++ < failFirstOpens,
    ),
  );
  return opens;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tc540_');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  // A container that DOES carry a preview large enough to clear the frozen
  // 2800 floor: without an injected fault every assertion below must find it.
  Future<String> writePreviewBearingDng() async => writeSyntheticDng(
    buildSyntheticDng(
      candidates: const [SyntheticCandidate(width: 3200, height: 2133)],
    ),
    dir: dir,
    name: 'preview_bearing.dng',
  );

  test(
    'control: an intact preview-bearing DNG yields its embedded JPEG in one open',
    () async {
      final path = await writePreviewBearingDng();
      DngEmbeddedJpegProbe? probe;
      final opens = await _withFlakyReads(0, () async {
        probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
          minLongEdge: 2800,
        );
      });
      expect(probe!.jpeg, isNotNull, reason: 'fixture must carry a preview');
      expect(opens, 1, reason: 'the happy path must stay a single open');
    },
  );

  test(
    'TC-540a: a transient read failure is retried, not latched as "no preview"',
    () async {
      final path = await writePreviewBearingDng();
      DngEmbeddedJpegProbe? probe;
      final opens = await _withFlakyReads(1, () async {
        probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
          minLongEdge: 2800,
        );
      });
      // BEFORE the fix: the first open's reads fail, every read degrades to
      // null, the walk reports "no candidate", and the caller routes the photo
      // to a full RAW decode for the rest of the session.
      // AFTER the fix: the I/O error is recognised as such and the walk is
      // retried, so the intact preview is served.
      expect(
        probe!.jpeg,
        isNotNull,
        reason: 'a transient read error must be retried, not reported as '
            '"this container has no embedded preview"',
      );
      expect(probe!.jpeg!.width, 3200);
      expect(opens, greaterThan(1), reason: 'the retry must re-open the file');
    },
  );

  test(
    'TC-540b: probeContent survives a transient read failure',
    () async {
      // probeContent is what feeds PrefetchScheduler.classify, i.e. the
      // cheap-vs-expensive verdict that is memoised first-writer-wins for the
      // whole folder. A hiccup here is what makes a photo RAW-decode for the
      // session.
      final path = await writePreviewBearingDng();
      ({bool jpegBitstream, int largestLongEdge, int? orientation})? content;
      await _withFlakyReads(1, () async {
        content = await DngEmbeddedJpegExtractor.probeContent(path);
      });
      expect(content, isNotNull, reason: 'must not report "unmeasurable"');
      expect(
        content!.largestLongEdge,
        3200,
        reason: 'the measured preview size must not shrink because one read '
            'failed — a shrunken measurement is what flips the item to the '
            'expensive (RAW decode) lane',
      );
    },
  );

  test(
    'TC-540d: a SHORT read (no exception) on the preview strip is retried',
    () async {
      // The exact shape measured on the user's volume: the ~8MB preview strip
      // comes back one byte short, nothing throws, and the walker reports the
      // container as having only unreadable previews -> RAW fallback for the
      // session.
      final path = await writePreviewBearingDng();
      var opens = 0;
      DngEmbeddedJpegProbe? probe;
      await IOOverrides.runZoned(() async {
        probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
          minLongEdge: 2800,
        );
      }, createFile: (p) => _ShortReadFile(
            Zone.root.run(() => File(p)),
            () => opens++ < 1,
          ));
      expect(
        probe!.jpeg,
        isNotNull,
        reason: 'a short read is an I/O fault, not evidence that the preview '
            'is unreadable',
      );
      expect(probe!.malformed, isFalse);
      expect(opens, greaterThan(1));
    },
  );

  test(
    'TC-540c: a genuinely preview-less container is NOT retried',
    () async {
      // The negative half: retrying an honest "no preview here" answer would
      // triple the cost of every preview-less RAW in the folder.
      final path = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 320, height: 213)],
        ),
        dir: dir,
        name: 'undersized.dng',
      );
      DngEmbeddedJpegProbe? probe;
      final opens = await _withFlakyReads(0, () async {
        probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
          minLongEdge: 2800,
        );
      });
      // AD-033 is untouched: a 320px preview stays rejected against the frozen
      // 2800 floor, and that rejection is final rather than retried.
      expect(probe!.jpeg, isNull);
      expect(opens, 1, reason: 'no I/O error occurred, so nothing to retry');
    },
  );
}
