import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes [bytes] to `<dir>/<name>` in a way that a subsequent `File.rename` /
/// `File.copy` on Windows will not trip over with
/// `PathAccessException (errno = 32, "used by another process")`.
///
/// ## Why this exists
///
/// The failing tests create a fixture file and then drive production code that
/// renames or copies it microseconds later. On POSIX that is fine. On Windows it
/// intermittently throws errno 32 because the just-written file can still have a
/// live handle when the rename runs.
///
/// There are two distinct sources of that lingering handle, and this helper
/// addresses them differently:
///
/// 1. **Our own write handle (deterministic).** `File.writeAsBytes` opens the
///    file through a streaming sink; on Windows the sink's close can be observed
///    lazily. Writing through a [RandomAccessFile] with an explicit
///    `flush()` + `close()` releases OUR handle before this future completes, so
///    the primary, self-inflicted cause is removed deterministically — not merely
///    made less likely.
///
/// 2. **An external transient handle (mitigated).** The search indexer or
///    Defender can grab a freshly created file for a scan. We cannot control
///    those processes from a test, so after our handle is closed we spin a short
///    bounded reopen loop: each iteration reopens the file (forcing a real
///    filesystem round-trip) and yields, giving a transient external handle time
///    to be released before the caller proceeds to rename it.
///
/// This is a FIXTURE-side settle only. It never wraps or retries the production
/// rename/copy, so a genuine rename defect still surfaces as a test failure —
/// the settle happens strictly before the code under test runs.
///
/// ponytail: the reopen loop removes our own deferred close deterministically but
/// can only *reduce* the window in which an external scanner re-locks the file in
/// the microseconds before the production rename. The only fully deterministic
/// cure for the external-locker case is a retry-on-sharing-violation wrapped
/// around `File.rename` / `File.copy` in `lib/services/library/photo_file_actions.dart`
/// and `lib/services/rename/rename_service.dart` (same shape as
/// `test/support/temp_dirs.dart`'s teardown). That is a production change and is
/// out of scope for this test-only task; raise it with the team lead if real
/// Windows users hit intermittent errno 32 in the shipped app.
Future<File> writeFixtureBytes(
  Directory dir,
  String name,
  List<int> bytes,
) async {
  final file = File(p.join(dir.path, name));
  final raf = await file.open(mode: FileMode.write);
  try {
    await raf.writeFrom(bytes);
    await raf.flush();
  } finally {
    await raf.close();
  }
  await _settle(file);
  return file;
}

/// String convenience wrapper around [writeFixtureBytes]; mirrors the behaviour
/// of `File.writeAsString` (UTF-8) for fixtures that later get renamed/copied.
Future<File> writeFixtureString(
  Directory dir,
  String name,
  String contents,
) =>
    writeFixtureBytes(dir, name, utf8.encode(contents));

/// Bounded, best-effort wait until [file] can be reopened cleanly. On POSIX the
/// first reopen succeeds immediately (the loop is a no-op). On Windows it forces
/// a filesystem round-trip and yields, letting a transient external handle drain.
/// It never throws: reaching the ceiling just returns.
Future<void> _settle(File file) async {
  const delays = <int>[0, 10, 20, 40, 80];
  for (var attempt = 0;; attempt++) {
    try {
      final raf = await file.open(mode: FileMode.append);
      await raf.close();
      return;
    } on FileSystemException {
      if (attempt >= delays.length) return;
      await Future<void>.delayed(Duration(milliseconds: delays[attempt]));
    }
  }
}
