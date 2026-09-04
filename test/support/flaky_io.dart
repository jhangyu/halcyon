import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// Fault-injecting filesystem wrappers for tests, shared by the TC-717 retry
// cases (transient read failure must not be reported as "no embedded preview").
//
// Injection is through `IOOverrides.runZoned(createFile: ...)`, the same seam
// photo_source_single_probe_test.dart already uses to count opens: no
// production seam is added for testability, and the extractor under test is
// exercised exactly as it ships.
//
// Two fault shapes, deliberately kept separate:
//   * THROWN error   -- the read raises (EIO and friends).
//   * SHORT read     -- the read returns fewer bytes than asked WITHOUT any
//                       error. This is the shape measured on the user's volume
//                       (docs/logs/2026-09-02/repro-experiment.md §3): the
//                       ~8MB preview strip arrives in one `readSync`, and a
//                       short return there was indistinguishable from "this
//                       container's declared previews are all unreadable".
// A test that only covers the first shape would miss the one that matters.

/// Base delegate: forwards everything used by the extractor to [inner] and
/// fails loudly on anything else, so an unanticipated route cannot be silently
/// mis-attributed to the fault being injected.
abstract class _DelegatingRandomAccessFile implements RandomAccessFile {
  _DelegatingRandomAccessFile(this.inner);

  final RandomAccessFile inner;

  @override
  Future<Uint8List> read(int count) => inner.read(count);

  @override
  RandomAccessFile setPositionSync(int position) {
    inner.setPositionSync(position);
    return this;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await inner.setPosition(position);
    return this;
  }

  @override
  int lengthSync() => inner.lengthSync();

  @override
  Future<int> length() => inner.length();

  @override
  Future<void> close() => inner.close();

  @override
  void closeSync() => inner.closeSync();

  @override
  String get path => inner.path;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Reads throw while [shouldFail] holds.
class ThrowingRandomAccessFile extends _DelegatingRandomAccessFile {
  ThrowingRandomAccessFile(super.inner, {required this.shouldFail});

  final bool shouldFail;

  Never _fail() => throw const FileSystemException(
    'simulated transient read error',
    'injected by test',
    OSError('Input/output error', 5),
  );

  @override
  Uint8List readSync(int count) => shouldFail ? _fail() : inner.readSync(count);

  @override
  Future<Uint8List> read(int count) async =>
      shouldFail ? _fail() : inner.read(count);
}

/// Reads come back ONE BYTE SHORT while [shouldTruncate] holds — no exception.
///
/// One byte, not a percentage: h2's first attempt truncated the FILE to 50% and
/// the test came back green because the 8MB strip still fitted inside the
/// surviving half (repro-experiment.md §3). Shortening every read by one byte
/// cannot miss the range under test, whatever the fixture's layout.
class ShortReadRandomAccessFile extends _DelegatingRandomAccessFile {
  ShortReadRandomAccessFile(super.inner, {required this.shouldTruncate});

  final bool shouldTruncate;

  @override
  Uint8List readSync(int count) {
    final bytes = inner.readSync(count);
    if (!shouldTruncate || bytes.length < 2) return bytes;
    return Uint8List.sublistView(bytes, 0, bytes.length - 1);
  }

  // Async counterpart of readSync above (2026-09-04 W4): the extractor now
  // reads through RandomAccessFile.read/setPosition instead of the Sync
  // pair, so the short-read fault must be injected on the same async path
  // the extractor actually calls, or the fault silently stops firing.
  @override
  Future<Uint8List> read(int count) async {
    final bytes = await inner.read(count);
    if (!shouldTruncate || bytes.length < 2) return bytes;
    return Uint8List.sublistView(bytes, 0, bytes.length - 1);
  }
}

/// A [File] whose opened handle is wrapped by [wrap].
class FaultInjectingFile implements File {
  FaultInjectingFile(this._inner, this._wrap);

  final File _inner;
  final RandomAccessFile Function(RandomAccessFile raf) _wrap;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _wrap(await _inner.open(mode: mode));

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _wrap(_inner.openSync(mode: mode));

  // Forwarded, not faulted (2026-09-05, P1b BLOCKER-3 test support): a caller
  // exercising `dartImageLoad` under fault injection hits
  // `File(path).exists()` before ever touching the extractor's read path --
  // that existence check is not part of what any fault shape here simulates,
  // and leaving it unimplemented makes every such call throw
  // `NoSuchMethodError` regardless of [failFirstOpens].
  @override
  Future<bool> exists() => _inner.exists();

  @override
  bool existsSync() => _inner.existsSync();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Result of a fault-injected run: what [body] produced, and how many times the
/// file was opened (i.e. whether a retry happened).
typedef FaultRun<T> = ({T value, int opens});

/// Runs [body] with the first [failFirstOpens] opens faulted.
///
/// [shape] selects thrown-vs-short reads. Opens beyond [failFirstOpens] behave
/// normally, which is what makes "the retry recovers" observable rather than
/// merely "the retry happened".
Future<FaultRun<T>> withInjectedReadFaults<T>({
  required int failFirstOpens,
  required ReadFaultShape shape,
  required Future<T> Function() body,
}) async {
  var opens = 0;
  late T value;
  await IOOverrides.runZoned(
    () async {
      value = await body();
    },
    // Zone.root escapes this override, so the wrapped File is a real one rather
    // than an infinite regress through the factory.
    createFile: (path) => FaultInjectingFile(Zone.root.run(() => File(path)), (
      raf,
    ) {
      final fault = opens++ < failFirstOpens;
      return switch (shape) {
        ReadFaultShape.thrown => ThrowingRandomAccessFile(
          raf,
          shouldFail: fault,
        ),
        ReadFaultShape.short => ShortReadRandomAccessFile(
          raf,
          shouldTruncate: fault,
        ),
      };
    }),
  );
  return (value: value, opens: opens);
}

enum ReadFaultShape { thrown, short }
