// Functional FFI probe for H-SIZED-SYMBOL / H-CEYX-SYMBOLS (OQ-1 ruling c).
// Format-agnostic: it tests the CAPABILITY (symbol reachable at runtime), not
// a symbol-table proxy.
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
//                                                  [symbol...]
// Zero or more trailing symbol names may be given; each is looked up and
// reported with its own PROBE-OK/PROBE-FAIL line. With no symbols given, the
// probe checks _defaultSymbol only (today's single-symbol behaviour). CI can
// pass the full CEYX_SYMBOLS set to functionally probe every entry point the
// Dart side looks up, or a name that cannot exist to demonstrate the RED
// state against the very library CI is green on, instead of having to keep a
// deliberately broken library around.
// Exit 0 = all given symbols reachable; 1 = any unresolved / library not
// loadable; 2 = usage.
import 'dart:ffi';
import 'dart:io';

// As of ceyx v0.1.19 the decode entry point the Dart side reaches for is
// ceyx_decode_into_buffer_oriented; the previous dng_decode_and_process_sized
// was deleted upstream (ceyx 53d61d1, decode-pool retirement). Kept in sync
// with SYMBOL in scripts/ci/assertions.py.
const _defaultSymbol = 'ceyx_decode_into_buffer_oriented';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: ffi_probe.dart <library-path> [symbol...]');
    exit(2);
  }
  final path = args.first;
  final symbols = args.length > 1 ? args.sublist(1) : const [_defaultSymbol];
  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(path);
  } catch (e) {
    stderr.writeln('PROBE-FAIL: $path: $e');
    exit(1);
  }
  final unresolved = <String>[];
  for (final symbol in symbols) {
    try {
      lib.lookup<NativeFunction<Void Function()>>(symbol);
      stdout.writeln('PROBE-OK: $symbol reachable in $path');
    } catch (e) {
      unresolved.add('$symbol ($e)');
    }
  }
  if (unresolved.isNotEmpty) {
    stderr.writeln('PROBE-FAIL: $path: unresolved: ${unresolved.join('; ')}');
    exit(1);
  }
  exit(0);
}
