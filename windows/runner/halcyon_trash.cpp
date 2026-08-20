// IFileOperation-backed implementation of the `halcyon/trash` channel.
//
// UNCOMPILED AND UNTESTED: authored on a macOS host.

#include "halcyon_native.h"

#include <windows.h>
// shobjidl_core.h must follow windows.h.
#include <objbase.h>
#include <shellapi.h>
#include <shobjidl_core.h>
#include <wrl/client.h>

#include <string>

using Microsoft::WRL::ComPtr;

namespace halcyon {
namespace {

TrashResult TrashFailure(const char* code, const char* message) {
  TrashResult result;
  result.ok = false;
  result.error_code = code;
  result.error_message = message;
  return result;
}

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  const int converted =
      ::MultiByteToWideChar(CP_UTF8, 0, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            length);
  if (converted <= 0) {
    return std::wstring();
  }
  return result;
}

}  // namespace

TrashResult TrashFile(const std::string& utf8_path) {
  const std::wstring path = Utf16FromUtf8(utf8_path);
  if (path.empty()) {
    return TrashFailure("INVALID_ARGS", "Path is empty or not valid UTF-8");
  }

  // Checked up front so a missing file reports NOT_FOUND rather than an opaque
  // shell HRESULT, matching macOS (AppDelegate.swift:113-118).
  if (::GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return TrashFailure("NOT_FOUND", "File does not exist");
  }

  ComPtr<IFileOperation> operation;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(&operation));
  if (FAILED(hr)) {
    return TrashFailure("TRASH_FAILED", "Cannot create shell file operation");
  }

  // FOF_ALLOWUNDO is the Recycle Bin request that works on every supported
  // release; FOFX_RECYCLEONDELETE (Windows 8+) additionally forces recycling
  // rather than a permanent delete when the shell would otherwise nuke the
  // file. FOF_SILENT/FOF_NOCONFIRMATION/FOF_NOERRORUI keep the operation
  // headless -- Halcyon reports failure through its own status line, and a
  // modal shell dialog inside a triage keyboard loop would be hostile.
  // FOFX_EARLYFAILURE is only meaningful together with FOF_NOERRORUI, which is
  // set here, and makes the operation stop on the first error instead of
  // silently continuing.
  const DWORD flags = FOF_ALLOWUNDO | FOF_SILENT | FOF_NOCONFIRMATION |
                      FOF_NOERRORUI | FOFX_RECYCLEONDELETE | FOFX_EARLYFAILURE;
  hr = operation->SetOperationFlags(flags);
  if (FAILED(hr)) {
    return TrashFailure("TRASH_FAILED", "Cannot configure file operation");
  }

  ComPtr<IShellItem> item;
  hr = ::SHCreateItemFromParsingName(path.c_str(), nullptr, IID_PPV_ARGS(&item));
  if (FAILED(hr)) {
    return TrashFailure("NOT_FOUND", "Cannot resolve file in the shell namespace");
  }

  hr = operation->DeleteItem(item.Get(), nullptr);
  if (FAILED(hr)) {
    return TrashFailure("TRASH_FAILED", "Cannot queue delete");
  }

  hr = operation->PerformOperations();
  if (FAILED(hr)) {
    return TrashFailure("TRASH_FAILED", "Move to Recycle Bin failed");
  }

  // PerformOperations reports S_OK even when the shell (or the user) stopped
  // the work, so success is only claimed after this second check. Without it a
  // silently-skipped delete would look like a completed one and Halcyon would
  // drop the photo from the list while the file is still on disk.
  BOOL aborted = FALSE;
  if (SUCCEEDED(operation->GetAnyOperationsAborted(&aborted)) && aborted) {
    return TrashFailure("TRASH_FAILED", "Move to Recycle Bin was aborted");
  }

  TrashResult result;
  result.ok = true;
  return result;
}

}  // namespace halcyon
