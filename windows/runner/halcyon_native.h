// Halcyon Windows native bridges.
//
// Declares the Recycle Bin bridge and the MethodChannel registration used by
// the Windows runner. The native image pipeline was deleted in M6 (F-04/06/07
// moved to a pure-Dart producer); only Trash and Open With remain native. The
// Dart contracts these must satisfy live in:
//   lib/services/trash_service.dart             (halcyon/trash)
//   lib/services/open_with_channel.dart         (halcyon/open_with)
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

// Owns Halcyon's two Windows MethodChannels for the lifetime of the engine.
class Channels {
 public:
  // Registers `halcyon/trash`'s handler immediately. `halcyon/open_with` is
  // created but gets NO handler: like macOS (AppDelegate.swift:80-86) it is
  // push-only, native -> Dart.
  explicit Channels(flutter::BinaryMessenger* messenger);
  ~Channels();

  Channels(const Channels&) = delete;
  Channels& operator=(const Channels&) = delete;

  // Sends |utf8_path| to Dart as `openFile`. Safe to call before Dart has
  // registered its handler: Flutter's channel buffers hold a platform -> Dart
  // message until a handler appears, which is the entire reason this channel
  // is push-only (open_with_channel.dart:6-11).
  void PushOpenFile(const std::string& utf8_path);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> trash_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> open_with_;
};

}  // namespace halcyon

#endif  // RUNNER_HALCYON_NATIVE_H_
