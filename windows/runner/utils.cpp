#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

// A double-clicked GUI process starts without stdout/stderr handles. The
// engine statically links its own CRT, which captures the std handles once,
// when flutter_windows.dll initializes; with none, every dart:io stdout/stderr
// write fails with "handle is invalid" (errno 6), which is fatal inside ceyx's
// decode worker isolates (errorsAreFatal). The engine and plugin DLLs are
// delay-loaded (windows/CMakeLists.txt) so this runs before that capture.
// Never use FlutterDesktopResyncOutputStreams() here: it always reopens on
// CONOUT$, which fails without a console and then fastfails in _dup2.
// HALCYON_STDIO_LOG=<path> sends the output to that file instead of NUL.
void EnsureStdOutputHandles() {
  HANDLE target = INVALID_HANDLE_VALUE;
  for (DWORD id : {STD_OUTPUT_HANDLE, STD_ERROR_HANDLE}) {
    HANDLE current = ::GetStdHandle(id);
    if (current != nullptr && current != INVALID_HANDLE_VALUE &&
        ::GetFileType(current) != FILE_TYPE_UNKNOWN) {
      continue;
    }
    if (target == INVALID_HANDLE_VALUE) {
#pragma warning(suppress : 4996)
      const wchar_t* log_path = _wgetenv(L"HALCYON_STDIO_LOG");
      if (log_path != nullptr && *log_path != L'\0') {
        target = ::CreateFileW(log_path, GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      }
      if (target == INVALID_HANDLE_VALUE) {
        target = ::CreateFileW(L"NUL", GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                               OPEN_EXISTING, 0, nullptr);
      }
    }
    if (target != INVALID_HANDLE_VALUE) ::SetStdHandle(id, target);
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
