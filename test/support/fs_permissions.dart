import 'dart:io';

/// Cross-platform helpers to make a directory genuinely non-writable (and to
/// restore it), so a test can exercise the app's real writability probe on every
/// OS instead of relying on a POSIX-only mechanism.
///
/// ## Why this exists
///
/// The read-only-folder test used `Process.run('chmod', ['a-w', dir])` to block
/// writes. `chmod` does not exist on Windows: the call is a silent no-op, the
/// directory stays writable, the production probe (create+delete
/// `.halcyon_write_probe`) correctly reports writable, and the assertion that a
/// read-only warning appears fails. That is a fixture defect, not a production
/// defect — the probe is the correct portable check.
///
/// [makeDirReadOnly] produces a directory in which creating a new file fails on
/// each platform's own terms, so the probe deterministically reports non-writable:
///
/// - POSIX: `chmod a-w` clears the write bit; `open(O_CREAT)` in the dir → EACCES.
/// - Windows: `icacls /deny *S-1-1-0:(WD)` adds a Deny "Write Data / Add File"
///   ACE for the Everyone SID (`*S-1-1-0`). A Deny ACE takes precedence over any
///   Allow, so `CreateFile` for a new file in the directory returns
///   ERROR_ACCESS_DENIED — the probe cannot create `.halcyon_write_probe` and
///   reports non-writable. This is a real ACL change, not a simulation, so the
///   Windows assertion is exercised for real rather than skipped.
///
/// [makeDirWritable] reverses it and must run in teardown BEFORE deleting the
/// directory, so cleanup is not itself blocked.
Future<void> makeDirReadOnly(Directory dir) async {
  if (Platform.isWindows) {
    await Process.run('icacls', [dir.path, '/deny', '*S-1-1-0:(WD)']);
  } else {
    await Process.run('chmod', ['a-w', dir.path]);
  }
}

/// Restores write access removed by [makeDirReadOnly]. Best-effort: on Windows it
/// removes the Deny ACE for the Everyone SID; on POSIX it re-adds the owner write
/// bit. Safe to call even if the directory was never made read-only.
Future<void> makeDirWritable(Directory dir) async {
  if (Platform.isWindows) {
    await Process.run('icacls', [dir.path, '/remove:d', '*S-1-1-0']);
  } else {
    await Process.run('chmod', ['u+w', dir.path]);
  }
}
