// MethodChannel registration for Halcyon's Windows native bridges.
//
// UNCOMPILED AND UNTESTED: authored on a macOS host.
//
// Channel names, method names, argument keys and result shapes here must match
// the Dart side byte for byte. A mismatched string does not raise an error --
// it silently makes the feature dead -- so each one is cited against its Dart
// definition below.

#include "halcyon_native.h"

#include <flutter/standard_method_codec.h>

// windows.h is included after the Flutter headers on purpose: it defines a
// pile of unprefixed macros (CreateFile, GetObject, ...) that can rewrite
// identifiers inside any header parsed after it.
#include <windows.h>

#include <utility>
#include <variant>

namespace halcyon {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* ValueFor(const EncodableMap& map, const char* key) {
  const auto entry = map.find(EncodableValue(std::string(key)));
  return entry == map.end() ? nullptr : &entry->second;
}

std::string StringArgument(const EncodableMap& map,
                           const char* key,
                           const std::string& fallback) {
  if (const EncodableValue* value = ValueFor(map, key)) {
    if (const auto* text = std::get_if<std::string>(value)) {
      return *text;
    }
  }
  return fallback;
}

}  // namespace

Channels::Channels(flutter::BinaryMessenger* messenger) {
  const auto& codec = flutter::StandardMethodCodec::GetInstance();

  // trash_service.dart:7 (channel), :11 (method `trashFile` and key `path`).
  trash_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "halcyon/trash", &codec);
  trash_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "trashFile") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("INVALID_ARGS", "Missing path");
          return;
        }
        const std::string path = StringArgument(*arguments, "path", "");
        if (path.empty()) {
          result->Error("INVALID_ARGS", "Missing path");
          return;
        }
        // Runs inline on the platform thread by requirement, not by accident:
        // IFileOperation is STA-only and the platform thread is the app's STA.
        const TrashResult outcome = TrashFile(path);
        if (!outcome.ok) {
          result->Error(outcome.error_code, outcome.error_message,
                        EncodableValue(path));
          return;
        }
        // trash_service.dart:11 awaits invokeMethod<void>, so a null result.
        result->Success();
      });

  // open_with_channel.dart:22 (channel), :28 (method `openFile`). Deliberately
  // has NO method call handler: this channel is push-only, native -> Dart,
  // exactly as on macOS (AppDelegate.swift:80-86).
  open_with_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "halcyon/open_with", &codec);
}

Channels::~Channels() {
  // Handlers are owned by the binary messenger and outlive the channel
  // objects, so they are unregistered explicitly here (see the note on
  // MethodChannel::SetMethodCallHandler). Both handlers capture nothing, so
  // there is no dangling state either way, but leaving a live handler bound to
  // a destroyed channel is exactly the shape of a later use-after-free.
  if (trash_) {
    trash_->SetMethodCallHandler(nullptr);
  }
}

void Channels::PushOpenFile(const std::string& utf8_path) {
  if (utf8_path.empty() || !open_with_) {
    return;
  }
  // open_with_channel.dart:29-30 reads call.arguments as a bare String, not a
  // map, so the argument is sent as a bare string.
  open_with_->InvokeMethod("openFile",
                           std::make_unique<EncodableValue>(utf8_path));
}

std::string FirstExistingFileArgument(
    const std::vector<std::string>& arguments) {
  for (const std::string& argument : arguments) {
    if (argument.empty() || argument.front() == '-') {
      continue;
    }
    const int length = ::MultiByteToWideChar(CP_UTF8, 0, argument.data(),
                                             static_cast<int>(argument.size()),
                                             nullptr, 0);
    if (length <= 0) {
      continue;
    }
    std::wstring wide(static_cast<size_t>(length), L'\0');
    if (::MultiByteToWideChar(CP_UTF8, 0, argument.data(),
                              static_cast<int>(argument.size()), wide.data(),
                              length) <= 0) {
      continue;
    }
    const DWORD attributes = ::GetFileAttributesW(wide.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
      return argument;
    }
  }
  return std::string();
}

}  // namespace halcyon
