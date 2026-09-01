// Selects the working-set trim implementation for the current compilation
// target: the real one wherever the foreign-function interface exists, and an
// inert no-op on the web build, which has no way to reach the operating
// system's memory APIs.
//
// Callers import THIS path and nothing else, so the selection is invisible to
// them. See working_set_trim_io.dart for the behaviour and the C-3 discussion.
//
// The guard is the FFI capability itself, which is the precise thing being
// branched on; guarding on the host-runtime library instead would only be a
// proxy for it. The default uri must name a real library, which is why the
// no-op lives in its own file rather than inline here.

export 'working_set_trim_stub.dart'
    if (dart.library.ffi) 'working_set_trim_io.dart';
