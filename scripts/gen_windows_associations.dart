// Emits windows/runner/halcyon_associations.reg: a ProgID "Halcyon.Photo"
// registered under HKCU\Software\Classes for every extension in
// SupportedPhotoFormats.supportedExtensions (M6 F-18). Generated from that
// single source so the .reg extension list can never drift from the app's
// actual supported formats. Import target is the loose exe build_apps.py
// produces today (no MSIX/installer step exists yet — see the M6 execution
// plan P4.4 decision paragraph for why the registry route was chosen).
import 'dart:io';

import '../lib/models/supported_photo_formats.dart';

/// Encodes [value] as a .reg REG_EXPAND_SZ line: `hex(2):` followed by the
/// UTF-16LE bytes (+ null terminator) as comma-separated hex pairs. Plain
/// `@="..."` imports as REG_SZ, which Windows does NOT environment-expand in
/// a shell\open\command value — %LOCALAPPDATA% would be passed through
/// literally and the launch would silently fail. hex(2) is the only .reg
/// syntax for REG_EXPAND_SZ.
String regExpandSzLine(String value) {
  final units = value.codeUnits.toList()..add(0); // UTF-16LE + NUL terminator
  final bytes = <int>[];
  for (final u in units) {
    bytes.add(u & 0xff);
    bytes.add((u >> 8) & 0xff);
  }
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(',');
  return '@=hex(2):$hex';
}

void main() {
  const progId = 'Halcyon.Photo';
  // %LOCALAPPDATA%\Halcyon\halcyon.exe matches the loose-exe layout
  // build_apps.py's windows phase produces (build/windows/x64/runner/Release).
  const exePath = r'%LOCALAPPDATA%\Halcyon\halcyon.exe';
  final exts = SupportedPhotoFormats.supportedExtensions.toList()..sort();
  final command = '"$exePath" "%1"';

  // regedit expects CRLF (its own exports are UTF-16LE+CRLF); build_apps.py
  // regenerates this file on the Windows host at build time, so `git
  // autocrlf` never gets a chance to fix up LF-only output. Build as a line
  // list and join with \r\n explicitly rather than StringBuffer.writeln
  // (which emits bare \n) so every line, including the last, is CRLF.
  final lines = <String>[
    'Windows Registry Editor Version 5.00',
    '',
    '[HKEY_CURRENT_USER\\Software\\Classes\\$progId]',
    '@="Halcyon Photo"',
    '',
    '[HKEY_CURRENT_USER\\Software\\Classes\\$progId\\shell\\open\\command]',
    regExpandSzLine(command),
  ];

  for (final ext in exts) {
    lines
      ..add('')
      ..add('[HKEY_CURRENT_USER\\Software\\Classes\\$ext]')
      ..add('@="$progId"');
  }

  final out = File('windows/runner/halcyon_associations.reg');
  out.writeAsStringSync('${lines.join('\r\n')}\r\n');
  stdout.writeln(
    'wrote ${out.path} (${exts.length} extensions: ${exts.join(', ')})',
  );
}
