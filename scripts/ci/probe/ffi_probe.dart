// Functional FFI probe for H-SIZED-SYMBOL (OQ-1 ruling c). Format-agnostic: it
// tests the CAPABILITY (symbol reachable at runtime), not a symbol-table proxy.
//
// Why not nm/dumpbin: symbol-table presence is valid on Mach-O/ELF only by the
// coincidence of permissive default visibility, and is structurally invalid on
// Windows PE, where nothing is exported unless the build says so. This probe
// asks the same question every platform's loader answers at runtime, so one
// instrument is valid on all three.
//
// Standalone by design: it is NOT part of the Halcyon package, imports nothing
// from lib/, and adds no pubspec dependency (載體中立).
//
// Usage: dart run scripts/ci/probe/ffi_probe.dart <path-to-decoder-library>
// Exit 0 = symbol reachable; 1 = not reachable / library not loadable; 2 = usage.
import 'dart:ffi';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: ffi_probe.dart <library-path>');
    exit(2);
  }
  final path = args.single;
  try {
    final lib = DynamicLibrary.open(path);
    lib.lookup<NativeFunction<Void Function()>>('dng_decode_and_process_sized');
    stdout.writeln('PROBE-OK: dng_decode_and_process_sized reachable in $path');
    exit(0);
  } catch (e) {
    stderr.writeln('PROBE-FAIL: $path: $e');
    exit(1);
  }
}
