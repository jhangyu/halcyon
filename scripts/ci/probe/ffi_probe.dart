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
//                                                  [symbol-name]
// The optional second argument overrides the symbol looked up. CI never passes
// it; it exists so the RED state of this probe can be demonstrated against the
// very library CI is green on (pass a name that cannot exist), instead of
// having to keep a deliberately broken library around.
// Exit 0 = symbol reachable; 1 = not reachable / library not loadable; 2 = usage.
import 'dart:ffi';
import 'dart:io';

// As of ceyx v0.1.19 the decode entry point the Dart side reaches for is
// ceyx_decode_into_buffer_oriented; the previous dng_decode_and_process_sized
// was deleted upstream (ceyx 53d61d1, decode-pool retirement). Kept in sync
// with SYMBOL in scripts/ci/assertions.py.
const _defaultSymbol = 'ceyx_decode_into_buffer_oriented';

void main(List<String> args) {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln('usage: ffi_probe.dart <library-path> [symbol-name]');
    exit(2);
  }
  final path = args.first;
  final symbol = args.length == 2 ? args[1] : _defaultSymbol;
  try {
    final lib = DynamicLibrary.open(path);
    lib.lookup<NativeFunction<Void Function()>>(symbol);
    stdout.writeln('PROBE-OK: $symbol reachable in $path');
    exit(0);
  } catch (e) {
    stderr.writeln('PROBE-FAIL: $path: $e');
    exit(1);
  }
}
