import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Registers a best-effort, Windows-tolerant teardown that removes [dir] after
/// the current test finishes.
///
/// ## Why this exists
///
/// The idiomatic teardown `addTearDown(() => dir.delete(recursive: true))` is a
/// portability trap. On POSIX (macOS/Linux) unlinking a directory tree succeeds
/// even while a file inside it still has an open handle — the inode is reclaimed
/// once the last handle closes. On Windows the same delete THROWS:
///
///   PathAccessException: Deletion failed ...
///   (OS Error: The process cannot access the file because it is being used by
///    another process, errno = 32)
///
/// A throwing teardown fails an otherwise-passing test. This is exactly the
/// class of defect that stays invisible on the developer's machine and only
/// surfaces once a Windows CI runner exists.
///
/// ## Contract
///
/// Cleanup of a scratch temp directory is inherently best-effort: it lives under
/// the OS temp root, which the OS reclaims regardless of whether we delete it.
/// The only correct failure mode for this teardown is therefore "retry briefly,
/// then give up SILENTLY" — it must never throw, because throwing would convert
/// a transient open-handle race into a spurious test failure.
///
/// The implementation is intentionally unconditional (no `Platform.isWindows`
/// branch): a single code path that behaves correctly everywhere is what keeps
/// this defect from hiding on non-Windows machines. The retry loop is harmless
/// on POSIX (the first attempt succeeds) and load-bearing on Windows (it gives
/// pending async handles a moment to close).
///
/// ponytail: fixed retry schedule (5 attempts, 20ms→100ms backoff) rather than
/// coordinating with the actual handle owners. Adequate because these temp trees
/// are tiny and handles are released synchronously at test end; if a future test
/// holds a handle open for >~300ms after its body completes, raise the ceiling
/// or close the handle explicitly instead of leaning on this backoff.
void addTempDirTeardown(FileSystemEntity dir) {
  addTearDown(() => deleteTempDir(dir));
}

/// Best-effort, Windows-tolerant recursive delete of a scratch temp entity.
///
/// Use this directly inside a `tearDown`/`tearDownAll` body (which already IS a
/// teardown, so [addTempDirTeardown] would double-register). Same contract as
/// above: retries then gives up silently, never throws. An existence check is
/// unnecessary — a missing entity is treated as already-cleaned.
Future<void> deleteTempDir(FileSystemEntity dir) async {
  const delays = <int>[20, 40, 60, 80, 100];
  for (var attempt = 0; ; attempt++) {
    try {
      if (!await dir.exists()) return;
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= delays.length) {
        // Best-effort ceiling reached. Swallow: the OS reclaims the temp root,
        // and failing a passing test over scratch cleanup is never correct.
        return;
      }
      await Future<void>.delayed(Duration(milliseconds: delays[attempt]));
    }
  }
}
