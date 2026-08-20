// Halcyon Windows native bridges.
//
// Declares the non-RAW image pipeline, the Recycle Bin bridge, and the
// MethodChannel registration used by the Windows runner. The Dart contracts
// these must satisfy live in:
//   lib/services/native_thumbnail_service.dart  (halcyon/thumbnail)
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

// Outcome of a native image request.
//
// Mirrors the Dart-side `NativeImageResult` split (native_thumbnail_service.dart
// :36-69) minus the `NativeImageNeedsRawDecode` variant, which Windows never
// emits this round: emitting `NO_EMBEDDED_PREVIEW` would instruct Dart to run a
// `DngFullDecoder` that has no Windows build path at all (see
// docs/logs/2026-08-21/premise-audit-platforms.md).
struct ImageResult {
  bool ok = false;
  std::vector<uint8_t> bytes;  // Encoded JPEG; only meaningful when |ok|.
  std::string error_code;      // Only meaningful when !|ok|.
  std::string error_message;
};

// Outcome of a Recycle Bin request. Dart only distinguishes success from
// failure (trash_service.dart:9-19), but the code is kept for log fidelity.
struct TrashResult {
  bool ok = false;
  std::string error_code;
  std::string error_message;
};

// True when |lowercase_utf8_path| ends in an extension Halcyon treats as RAW.
// The list mirrors macos/Runner/AppDelegate.swift:312-318 exactly.
bool IsRawExtension(const std::string& lowercase_utf8_path);

// Decodes |utf8_path| and returns JPEG-encoded bytes capped at |target_size|
// on the long edge. |purpose| is one of "sidebarThumbnail" / "preview" /
// "export" (ImageRequestPurpose.platformValue, native_thumbnail_service.dart
// :5-18). RAW input always fails with code "RAW_UNSUPPORTED".
ImageResult RequestImage(const std::string& utf8_path,
                         const std::string& purpose,
                         int target_size);

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

// Owns Halcyon's three Windows MethodChannels for the lifetime of the engine.
class Channels {
 public:
  // Registers `halcyon/thumbnail` and `halcyon/trash` handlers immediately.
  // `halcyon/open_with` is created but gets NO handler: like macOS
  // (AppDelegate.swift:80-86) it is push-only, native -> Dart.
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
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> thumbnail_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> trash_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> open_with_;
};

}  // namespace halcyon

#endif  // RUNNER_HALCYON_NATIVE_H_
