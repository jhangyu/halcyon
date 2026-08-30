import 'dart:io' show File, Platform, Process;

/// Total physical RAM of the host machine.
///
/// Cross-platform by construction: every desktop target Halcyon ships
/// (macOS/Linux/Windows) has a cheap, dependency-free way to read this
/// without a native plugin --
///  - macOS: `sysctl -n hw.memsize`
///  - Linux: `/proc/meminfo`'s `MemTotal:` line
///  - Windows: a `Get-CimInstance Win32_ComputerSystem` PowerShell one-liner
///
/// This intentionally branches on `Platform.isX` (a deviation from this
/// repo's C-3 "no platform-conditional branches in lib/" convention) --
/// isolated to this single file, as C-3's own carve-out allows. See
/// memory.md for the AD entry. This replaced a `MethodChannel` +
/// macOS-only `AppDelegate.swift` handler: that mechanism only ever
/// answered on macOS (every other platform, including Linux/Windows which
/// this class now also answers on, silently fell to the floor policy), and
/// had a cold-start ordering hazard between Dart's `main()` and the
/// handler's registration in `applicationDidFinishLaunching`.
///
/// Every producer method here is called through a top-level try/catch in
/// [totalPhysicalBytes] and never throws; any failure (missing binary,
/// unexpected output, unreadable file) is treated the same as "no
/// platform answer" -- i.e. null, which every consumer reads as "use the
/// floor sizing".
class DeviceMemory {
  /// Total physical memory in bytes, or null when it can't be determined
  /// (unsupported platform, or the platform's usual mechanism failed).
  ///
  /// Never throws. A non-positive reading is treated as absent: a zero or
  /// negative RAM figure is a broken read, not a small machine, and must
  /// not be fed to the sizing ladder.
  static Future<int?> totalPhysicalBytes() async {
    try {
      final int? bytes;
      if (Platform.isMacOS) {
        bytes = await _macosPhysicalBytes();
      } else if (Platform.isLinux) {
        bytes = _linuxPhysicalBytes();
      } else if (Platform.isWindows) {
        bytes = await _windowsPhysicalBytes();
      } else {
        bytes = null;
      }
      if (bytes == null || bytes <= 0) return null;
      return bytes;
    } catch (_) {
      // Any I/O/process failure (missing binary, permission, unreadable
      // file, unparseable output) collapses to "no reading" -- see class
      // doc.
      return null;
    }
  }

  static Future<int?> _macosPhysicalBytes() async {
    final result = await Process.run('sysctl', ['-n', 'hw.memsize']);
    if (result.exitCode != 0) return null;
    return parseMacosSysctlOutput(result.stdout as String);
  }

  static int? _linuxPhysicalBytes() {
    return parseLinuxMeminfo(File('/proc/meminfo').readAsStringSync());
  }

  static Future<int?> _windowsPhysicalBytes() async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
    ]);
    if (result.exitCode != 0) return null;
    return parseWindowsPowershellOutput(result.stdout as String);
  }

  /// Pure parsing, exposed for testing without spawning a process.
  static int? parseMacosSysctlOutput(String stdout) =>
      int.tryParse(stdout.trim());

  /// Pure parsing, exposed for testing without touching the filesystem.
  ///
  /// `/proc/meminfo`'s `MemTotal:` line reports kibibytes, e.g.
  /// `MemTotal:       16384000 kB`.
  static int? parseLinuxMeminfo(String meminfoContents) {
    for (final line in meminfoContents.split('\n')) {
      if (!line.startsWith('MemTotal:')) continue;
      final kib = int.tryParse(RegExp(r'\d+').stringMatch(line) ?? '');
      return kib == null ? null : kib * 1024;
    }
    return null;
  }

  /// Pure parsing, exposed for testing without spawning a process.
  static int? parseWindowsPowershellOutput(String stdout) =>
      int.tryParse(stdout.trim());
}
