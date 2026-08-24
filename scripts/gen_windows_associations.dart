// Emits windows/runner/halcyon_associations.reg: a ProgID "Halcyon.Photo"
// registered under HKCU\Software\Classes for every extension in
// SupportedPhotoFormats.supportedExtensions (M6 F-18). Generated from that
// single source so the .reg extension list can never drift from the app's
// actual supported formats. Import target is the loose exe build_apps.py
// produces today (no MSIX/installer step exists yet — see the M6 execution
// plan P4.4 decision paragraph for why the registry route was chosen).
import 'dart:io';

import '../lib/models/supported_photo_formats.dart';

void main() {
  const progId = 'Halcyon.Photo';
  // %LOCALAPPDATA%\Halcyon\halcyon.exe matches the loose-exe layout
  // build_apps.py's windows phase produces (build/windows/x64/runner/Release).
  const exePath = r'%LOCALAPPDATA%\Halcyon\halcyon.exe';
  final exts = SupportedPhotoFormats.supportedExtensions.toList()..sort();

  final buffer = StringBuffer()
    ..writeln('Windows Registry Editor Version 5.00')
    ..writeln()
    ..writeln('[HKEY_CURRENT_USER\\Software\\Classes\\$progId]')
    ..writeln('@="Halcyon Photo"')
    ..writeln()
    ..writeln(
      '[HKEY_CURRENT_USER\\Software\\Classes\\$progId\\shell\\open\\command]',
    )
    ..writeln('@="\\"$exePath\\" \\"%1\\""');

  for (final ext in exts) {
    buffer
      ..writeln()
      ..writeln('[HKEY_CURRENT_USER\\Software\\Classes\\$ext]')
      ..writeln('@="$progId"');
  }

  final out = File('windows/runner/halcyon_associations.reg');
  out.writeAsStringSync('${buffer.toString()}\n');
  stdout.writeln(
    'wrote ${out.path} (${exts.length} extensions: ${exts.join(', ')})',
  );
}
