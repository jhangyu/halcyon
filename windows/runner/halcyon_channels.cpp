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

  // memory_pressure_monitor.dart (channel `halcyon/memory_pressure`, method
  // `memoryPressureLevelChanged`, bare-String argument). Push-only for the
  // same reason as open_with.
  memory_pressure_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "halcyon/memory_pressure", &codec);

  StartMemoryPressureWatch();
}

// ---------------------------------------------------------------------------
// Low-memory watch (WP4.4 / spec S3.4)
//
// UNVERIFIED-ON-WINDOWS: everything from here to PushMemoryPressureLevel was
// authored on a macOS host and has NEVER been compiled or run on Windows,
// inheriting the status this file's header already declares. The macOS live
// proof of the pressure path says nothing about this code. Do not report it as
// working; see docs/logs/2026-08-21/windows-verification-runbook.md.
//
// CreateMemoryResourceNotification(LowMemoryResourceNotification) does NOT
// deliver a callback: it returns a handle that is SIGNALLED while physical
// memory is low. Something has to wait on it, hence a dedicated thread.
//
// Why the thread also polls with a timeout rather than blocking forever: the
// handle stays signalled for as long as memory is low, so a bare
// WaitForMultipleObjects(INFINITE) would return instantly and spin. Each wake
// therefore READS the current state with QueryMemoryResourceNotification and
// pushes only on a transition. The low notification maps to "warning"; its
// complement (the query reporting not-low) maps to "normal".
// ---------------------------------------------------------------------------

namespace {

// Window message used to hop a level change onto the platform thread.
constexpr UINT kMemoryPressureMessage = WM_USER + 0x51;

LRESULT CALLBACK PressureWindowProc(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  if (message == kMemoryPressureMessage) {
    auto* channels = reinterpret_cast<Channels*>(
        ::GetWindowLongPtr(window, GWLP_USERDATA));
    if (channels != nullptr) {
      channels->PushMemoryPressureLevel(wparam == 0 ? "normal" : "warning");
    }
    return 0;
  }
  return ::DefWindowProc(window, message, wparam, lparam);
}

const wchar_t kPressureWindowClass[] = L"HalcyonMemoryPressureWindow";

}  // namespace

void Channels::StartMemoryPressureWatch() {
  // Message-only window, created HERE (the platform thread) so its window
  // procedure runs on the platform thread's message loop.
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = PressureWindowProc;
  window_class.hInstance = ::GetModuleHandle(nullptr);
  window_class.lpszClassName = kPressureWindowClass;
  ::RegisterClassW(&window_class);  // Harmless if already registered.
  HWND window = ::CreateWindowExW(0, kPressureWindowClass, L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr,
                                  window_class.hInstance, nullptr);
  if (window == nullptr) {
    return;  // No window, no watcher: pressure response simply stays off.
  }
  ::SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  pressure_window_ = window;

  memory_notification_ =
      ::CreateMemoryResourceNotification(LowMemoryResourceNotification);
  if (memory_notification_ == nullptr) {
    return;
  }
  memory_watch_stop_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (memory_watch_stop_ == nullptr) {
    ::CloseHandle(memory_notification_);
    memory_notification_ = nullptr;
    return;
  }
  memory_watch_thread_ = std::thread(&Channels::WatchMemoryPressure, this);
}

void Channels::WatchMemoryPressure() {
  bool last_low = false;
  for (;;) {
    HANDLE waits[2] = {static_cast<HANDLE>(memory_watch_stop_),
                       static_cast<HANDLE>(memory_notification_)};
    const DWORD wake = ::WaitForMultipleObjects(2, waits, FALSE, 1000);
    if (wake == WAIT_OBJECT_0) {
      return;  // Shutdown event: the only exit.
    }
    BOOL low = FALSE;
    if (!::QueryMemoryResourceNotification(
            static_cast<HANDLE>(memory_notification_), &low)) {
      continue;
    }
    const bool is_low = low != FALSE;
    if (is_low == last_low) {
      continue;
    }
    last_low = is_low;
    ::PostMessage(static_cast<HWND>(pressure_window_), kMemoryPressureMessage,
                  is_low ? 1 : 0, 0);
  }
}

void Channels::StopMemoryPressureWatch() {
  if (memory_watch_stop_ != nullptr) {
    ::SetEvent(static_cast<HANDLE>(memory_watch_stop_));
  }
  if (memory_watch_thread_.joinable()) {
    memory_watch_thread_.join();
  }
  if (memory_watch_stop_ != nullptr) {
    ::CloseHandle(static_cast<HANDLE>(memory_watch_stop_));
    memory_watch_stop_ = nullptr;
  }
  if (memory_notification_ != nullptr) {
    ::CloseHandle(static_cast<HANDLE>(memory_notification_));
    memory_notification_ = nullptr;
  }
  if (pressure_window_ != nullptr) {
    ::DestroyWindow(static_cast<HWND>(pressure_window_));
    pressure_window_ = nullptr;
  }
}

void Channels::PushMemoryPressureLevel(const char* level) {
  if (memory_pressure_ == nullptr || level == nullptr) {
    return;
  }
  if (last_pressure_level_ == level) {
    return;
  }
  last_pressure_level_ = level;
  // Bare String argument, matching open_with's convention and
  // memory_pressure_monitor.dart's MemoryPressureLevel.fromWireName.
  memory_pressure_->InvokeMethod(
      "memoryPressureLevelChanged",
      std::make_unique<EncodableValue>(std::string(level)));
}

Channels::~Channels() {
  // FIRST: the watcher thread must be gone before anything it touches is. It
  // posts to |pressure_window_| and, through the window proc, invokes
  // |memory_pressure_| -- both of which are about to be destroyed.
  StopMemoryPressureWatch();
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
