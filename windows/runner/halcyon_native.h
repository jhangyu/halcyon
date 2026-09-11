// Halcyon Windows native bridges.
//
// Declares the Recycle Bin bridge and the MethodChannel registration used by
// the Windows runner. The native image pipeline was deleted in M6 (F-04/06/07
// moved to a pure-Dart producer); only Trash and Open With remain native. The
// Dart contracts these must satisfy live in:
//   lib/services/trash_service.dart             (halcyon/trash)
//   lib/services/open_with_channel.dart         (halcyon/open_with)
//   lib/services/platform/memory_pressure_monitor.dart
//                                               (halcyon/memory_pressure)
//
// NOTHING IN THIS FILE OR ITS IMPLEMENTATION HAS BEEN COMPILED OR RUN.
// It was written on a macOS host, which cannot build Windows targets. See
// docs/logs/2026-08-21/windows-verification-runbook.md before trusting it.

#ifndef RUNNER_HALCYON_NATIVE_H_
#define RUNNER_HALCYON_NATIVE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace halcyon {

// Outcome of a Recycle Bin request. Dart only distinguishes success from
// failure (trash_service.dart:9-19), but the code is kept for log fidelity.
struct TrashResult {
  bool ok = false;
  std::string error_code;
  std::string error_message;
};

// Moves |utf8_path| to the Recycle Bin.
//
// MUST be called on a single-threaded-apartment thread: the IFileOperation
// reference page states the interface "can only be applied in a single-threaded
// apartment (STA) situation. It cannot be used for a multithreaded apartment."
// main.cpp initialises the platform thread with COINIT_APARTMENTTHREADED, so
// the platform thread qualifies and this is deliberately not moved to a worker.
TrashResult TrashFile(const std::string& utf8_path);

// Returns the first entry of |arguments| that names an existing file, or an
// empty string. Used to recover the "Open With" / shell-association path that
// Windows appends to the command line.
std::string FirstExistingFileArgument(const std::vector<std::string>& arguments);

// Owns Halcyon's Windows MethodChannels for the lifetime of the engine.
class Channels {
 public:
  // Registers `halcyon/trash`'s handler immediately. `halcyon/open_with` and
  // `halcyon/memory_pressure` are created but get NO handler: like macOS
  // (AppDelegate.swift) they are push-only, native -> Dart.
  explicit Channels(flutter::BinaryMessenger* messenger);
  ~Channels();

  Channels(const Channels&) = delete;
  Channels& operator=(const Channels&) = delete;

  // Sends |utf8_path| to Dart as `openFile`. Safe to call before Dart has
  // registered its handler: Flutter's channel buffers hold a platform -> Dart
  // message until a handler appears, which is the entire reason this channel
  // is push-only (open_with_channel.dart:6-11).
  void PushOpenFile(const std::string& utf8_path);

  // Sends a memory-pressure level to Dart as `memoryPressureLevelChanged`
  // (memory_pressure_monitor.dart). |level| is one of "normal" / "warning";
  // "critical" is macOS-only BY PLATFORM CAPABILITY, not by omission -- the
  // Windows low-memory notification is a TWO-STATE signal and has no third
  // level to map (lead ruling (e), 2026-09-11). Do not "complete" this by
  // inventing a threshold Windows does not provide.
  //
  // MUST be called on the platform thread; the watcher thread below routes
  // through a message-only window to guarantee that.
  void PushMemoryPressureLevel(const char* level);

 private:
  // Creates the message-only window, the notification handle and the watcher
  // thread. Called from the constructor, i.e. on the platform thread.
  void StartMemoryPressureWatch();

  // Signals the shutdown event, joins the watcher and releases the handles.
  // Called from the destructor BEFORE the channels are torn down.
  void StopMemoryPressureWatch();

  // Body of the low-memory watcher thread. See halcyon_channels.cpp for why a
  // dedicated thread exists at all: CreateMemoryResourceNotification returns a
  // waitable handle, not a callback.
  void WatchMemoryPressure();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> trash_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> open_with_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      memory_pressure_;

  // Low-memory watcher. The shutdown event and the join in the destructor are
  // MANDATORY, not tidy-up: a thread that outlives the engine's messenger is a
  // use-after-free, the exact hazard the channel-ordering note in
  // flutter_window.h already warns about.
  void* memory_notification_ = nullptr;  // HANDLE
  void* memory_watch_stop_ = nullptr;    // HANDLE (manual-reset event)
  std::thread memory_watch_thread_;

  // Message-only window used to hop from the watcher thread to the platform
  // thread. MethodChannel::InvokeMethod is not thread-safe and must run where
  // the engine lives.
  void* pressure_window_ = nullptr;  // HWND
  std::string last_pressure_level_;
};

}  // namespace halcyon

#endif  // RUNNER_HALCYON_NATIVE_H_
