#ifndef RUNNER_HALCYON_CHANNELS_H_
#define RUNNER_HALCYON_CHANNELS_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// Halcyon's Linux native bridges. Mirrors macos/Runner/AppDelegate.swift and
// windows/runner/halcyon_channels.cpp: the channels are owned by the runner,
// not registered as a Flutter plugin.
//
// COMPILE/RUNTIME STATUS: compiled by the `linux` leg of
// .github/workflows/ci.yml on every change. Runtime behaviour (Trash,
// "Open With", and the PSI-driven memory-pressure push below) is verified
// manually; see docs/logs/2026-09-12/wi1-linux-runbook.md and, for the PSI
// push specifically, the standalone docs/logs/2026-09-12/wi1-linux-psi-runbook.md.
typedef struct _HalcyonChannels HalcyonChannels;

// Registers halcyon/trash (handler), halcyon/open_with and
// halcyon/memory_pressure (push-only) on `messenger`. The memory-pressure
// channel additionally arms a real /proc/pressure/memory PSI trigger on
// Linux (OQ-R5 reversed the earlier register-and-silent plan); see the
// design doc cited in halcyon_channels.cc.
HalcyonChannels* halcyon_channels_new(FlBinaryMessenger* messenger);

// Pushes `path` to Dart on halcyon/open_with as method `openFile` with a bare
// String argument (open_with_channel.dart:36-38).
void halcyon_channels_push_open_file(HalcyonChannels* self,
                                     const gchar* path);

void halcyon_channels_free(HalcyonChannels* self);

G_END_DECLS

#endif  // RUNNER_HALCYON_CHANNELS_H_
