import 'dart:io';

/// Windows `ERROR_SHARING_VIOLATION` — "the process cannot access the file
/// because it is being used by another process".
const int kWindowsSharingViolation = 32;

/// Windows `ERROR_LOCK_VIOLATION` — a byte-range lock held by another process.
/// Same cause, same cure, and it arrives through the same code path.
const int kWindowsLockViolation = 33;

/// True when [error] is the transient "someone else has this file open"
/// failure that Windows raises from rename/copy/delete.
///
/// Deliberately narrow. Retrying a permission error, a disk-full error or a
/// "destination is a directory" error only delays an inevitable failure while
/// stalling the user's interactive batch, so those must fall straight through.
/// The discriminator is the OS error code carried on the exception, NOT the
/// message text and NOT the exception type: `PathAccessException` is also what
/// Dart throws for a plain POSIX `EACCES`, which is permanent and must not be
/// retried.
///
/// POSIX note: errno 32 is `EPIPE` and 33 is `EDOM`. Neither can be produced by
/// `File.rename`/`copy`/`delete` on a regular file, so matching the codes
/// unconditionally cannot misfire on macOS/Linux — see [retryOnSharingViolation]
/// for why the implementation stays unconditional.
bool isSharingViolation(Object error) {
  if (error is! FileSystemException) return false;
  final code = error.osError?.errorCode;
  return code == kWindowsSharingViolation || code == kWindowsLockViolation;
}

/// Runs [action], retrying only while it fails with a Windows sharing/lock
/// violation, and rethrowing the ORIGINAL exception once the budget is spent.
///
/// ## Why this exists
///
/// Halcyon moves, copies and renames the user's photographs. On Windows any of
/// those calls fails outright with
///
///   OS Error: The process cannot access the file because it is being used by
///   another process, errno = 32
///
/// whenever *any* process still holds an open handle on the file. Defender, the
/// Search indexer and backup agents routinely hold a handle on a photo for a
/// fraction of a second after it is touched, so a photographer pressing
/// "move starred" on a folder mid-scan gets failed items today with no retry.
/// POSIX has no equivalent: unlink and rename succeed regardless of open
/// handles. Halcyon itself is not the locker — `dartImageLoad` uses
/// `readAsBytes` and the EXIF read is isolate-scoped and fully awaited before
/// any rename — so this guards against an EXTERNAL holder we cannot coordinate
/// with. Waiting is the only available remedy.
///
/// ## Contract (do not weaken)
///
/// A genuine failure MUST still surface. When the budget is exhausted the
/// original exception propagates unchanged, so the existing batch error paths
/// (`processStarred failure:` / `Rename failure:`) still report the item to the
/// user. Turning this into a swallow would convert a visible failed item into
/// silent data loss, which is far worse than the bug it fixes. Each attempt is
/// a single whole filesystem call, so no attempt can leave a file half-moved:
/// rename either happened or did not.
///
/// Intentionally unconditional (no `Platform.isWindows` branch): a branch means
/// the shipped Windows path is never exercised on any developer's machine. On
/// POSIX the first attempt succeeds and the loop costs nothing.
///
/// ponytail: fixed 4-retry, 20/40/80/160ms schedule (~300ms worst case per
/// file) rather than watching for the handle to close. Adequate because AV and
/// indexer handles on a single photo are released in tens of milliseconds, and
/// because this runs in the user's interactive path — a longer schedule would
/// make a 500-photo batch that legitimately fails take minutes. If real Windows
/// telemetry shows locks outliving this window, raise the ceiling here (one
/// place) rather than at the call sites.
Future<T> retryOnSharingViolation<T>(
  Future<T> Function() action, {
  List<int> delaysMs = const <int>[20, 40, 80, 160],
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await action();
    } catch (e) {
      if (attempt >= delaysMs.length || !isSharingViolation(e)) rethrow;
      await Future<void>.delayed(Duration(milliseconds: delaysMs[attempt]));
    }
  }
}
