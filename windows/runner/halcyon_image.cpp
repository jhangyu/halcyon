// WIC-backed implementation of the `halcyon/thumbnail` channel.
//
// UNCOMPILED AND UNTESTED: authored on a macOS host. Every Win32/WIC signature
// used here was checked against Microsoft Learn; see the "APIs verified" list in
// docs/logs/2026-08-21/windows-verification-runbook.md, which also records which
// details were NOT verifiable and how to falsify them.

#include "halcyon_native.h"

#include <windows.h>
// These must follow windows.h.
// objbase.h  - CoCreateInstance, CreateStreamOnHGlobal, PROPVARIANT helpers.
// ocidl.h    - IPropertyBag2 / PROPBAG2 used for the JPEG encoder options.
// oleauto.h  - VariantInit / VariantClear. Included explicitly rather than
//              relying on windows.h -> ole2.h, which drops out entirely under
//              WIN32_LEAN_AND_MEAN.
#include <objbase.h>
#include <ocidl.h>
#include <oleauto.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <limits>

using Microsoft::WRL::ComPtr;

namespace halcyon {
namespace {

// Matches the macOS re-encode quality (AppDelegate.swift:502,
// `.compressionFactor: 0.8`).
constexpr float kJpegQuality = 0.8f;

// Fallback when the caller omits `targetSize`, matching AppDelegate.swift:39.
constexpr int kDefaultTargetSize = 4000;

ImageResult Fail(const char* code, const char* message) {
  ImageResult result;
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

bool HasSuffix(const std::string& value, const char* suffix) {
  const size_t suffix_length = std::strlen(suffix);
  return value.size() >= suffix_length &&
         value.compare(value.size() - suffix_length, suffix_length, suffix) == 0;
}

std::string LowerAscii(const std::string& value) {
  std::string result(value);
  std::transform(result.begin(), result.end(), result.begin(),
                 [](unsigned char character) {
                   return static_cast<char>(std::tolower(character));
                 });
  return result;
}

bool ReadWholeFile(const std::wstring& path, std::vector<uint8_t>* out) {
  const HANDLE file =
      ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  LARGE_INTEGER size = {};
  const LONGLONG max_readable =
      static_cast<LONGLONG>((std::numeric_limits<DWORD>::max)());
  if (!::GetFileSizeEx(file, &size) || size.QuadPart < 0 ||
      size.QuadPart > max_readable) {
    ::CloseHandle(file);
    return false;
  }
  out->resize(static_cast<size_t>(size.QuadPart));
  bool ok = true;
  if (!out->empty()) {
    DWORD read = 0;
    ok = ::ReadFile(file, out->data(), static_cast<DWORD>(out->size()), &read,
                    nullptr) != FALSE &&
         static_cast<size_t>(read) == out->size();
  }
  ::CloseHandle(file);
  if (!ok) {
    out->clear();
  }
  return ok;
}

// Reads the EXIF Orientation tag (IFD0 tag 274) via the WIC metadata query
// language. Query strings are the documented System.Photo.Orientation read
// paths for the JPEG and TIFF containers respectively. Anything missing,
// wrongly typed, or out of the 1..8 range degrades to 1, matching
// kDefaultExifOrientation (native_thumbnail_service.dart:73).
unsigned int ReadExifOrientation(IWICBitmapFrameDecode* frame) {
  ComPtr<IWICMetadataQueryReader> reader;
  if (FAILED(frame->GetMetadataQueryReader(&reader)) || !reader) {
    return 1;
  }
  static const wchar_t* const kQueries[] = {L"/app1/ifd/{ushort=274}",
                                            L"/ifd/{ushort=274}"};
  for (const wchar_t* query : kQueries) {
    PROPVARIANT value;
    ::PropVariantInit(&value);
    unsigned int found = 0;
    if (SUCCEEDED(reader->GetMetadataByName(query, &value)) &&
        value.vt == VT_UI2) {
      found = value.uiVal;
    }
    ::PropVariantClear(&value);
    if (found >= 1 && found <= 8) {
      return found;
    }
  }
  return 1;
}

// EXIF Orientation (1..8) -> WIC transform.
//
// Cases 1, 3, 6 and 8 (the pure rotations, which is what real cameras emit)
// are unambiguous. Cases 2, 4, 5 and 7 combine a flip with a rotation, and the
// relative order in which WIC applies the two was NOT confirmed from
// documentation -- see the unverified list in the runbook. This table is
// deliberately the single place to fix if a mirrored image comes out wrong.
WICBitmapTransformOptions TransformForOrientation(unsigned int orientation) {
  switch (orientation) {
    case 2:
      return WICBitmapTransformFlipHorizontal;
    case 3:
      return WICBitmapTransformRotate180;
    case 4:
      return WICBitmapTransformFlipVertical;
    case 5:
      return static_cast<WICBitmapTransformOptions>(
          WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
    case 6:
      return WICBitmapTransformRotate90;
    case 7:
      return static_cast<WICBitmapTransformOptions>(
          WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
    case 8:
      return WICBitmapTransformRotate270;
    default:
      return WICBitmapTransformRotate0;
  }
}

HRESULT EncodeJpeg(IWICImagingFactory* factory,
                   IWICBitmapSource* source,
                   std::vector<uint8_t>* out) {
  ComPtr<IStream> stream;
  HRESULT hr = ::CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (FAILED(hr)) {
    return hr;
  }

  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder);
  if (FAILED(hr)) {
    return hr;
  }
  hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) {
    return hr;
  }

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> options;
  hr = encoder->CreateNewFrame(&frame, &options);
  if (FAILED(hr)) {
    return hr;
  }

  if (options) {
    PROPBAG2 option = {};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT quality;
    ::VariantInit(&quality);
    quality.vt = VT_R4;
    quality.fltVal = kJpegQuality;
    // A codec that does not expose ImageQuality must not fail the encode, so
    // the result is intentionally ignored and the default quality is accepted.
    (void)options->Write(1, &option, &quality);
    ::VariantClear(&quality);
  }

  hr = frame->Initialize(options.Get());
  if (FAILED(hr)) {
    return hr;
  }

  UINT width = 0;
  UINT height = 0;
  hr = source->GetSize(&width, &height);
  if (FAILED(hr)) {
    return hr;
  }
  hr = frame->SetSize(width, height);
  if (FAILED(hr)) {
    return hr;
  }

  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) {
    return hr;
  }
  hr = frame->WriteSource(source, nullptr);
  if (FAILED(hr)) {
    return hr;
  }
  hr = frame->Commit();
  if (FAILED(hr)) {
    return hr;
  }
  hr = encoder->Commit();
  if (FAILED(hr)) {
    return hr;
  }

  // GlobalSize reports the ALLOCATED capacity, which GlobalReAlloc rounding
  // makes >= the logical stream length. Using it directly would append
  // uninitialised trailing bytes to every JPEG, so the authoritative length
  // comes from IStream::Stat and GlobalSize is only a safety clamp.
  STATSTG stat = {};
  hr = stream->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr)) {
    return hr;
  }
  HGLOBAL global = nullptr;
  hr = ::GetHGlobalFromStream(stream.Get(), &global);
  if (FAILED(hr)) {
    return hr;
  }
  const size_t capacity = static_cast<size_t>(::GlobalSize(global));
  const size_t logical = static_cast<size_t>(stat.cbSize.QuadPart);
  const size_t length = (std::min)(capacity, logical);
  if (length == 0) {
    return E_FAIL;
  }
  void* const data = ::GlobalLock(global);
  if (data == nullptr) {
    return E_FAIL;
  }
  const uint8_t* const begin = static_cast<const uint8_t*>(data);
  out->assign(begin, begin + length);
  ::GlobalUnlock(global);
  return S_OK;
}

ImageResult DecodeAndReencode(const std::wstring& path, int target_size) {
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    return Fail("LOAD_FAILED", "WIC imaging factory unavailable");
  }

  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                          WICDecodeMetadataCacheOnDemand,
                                          &decoder);
  if (FAILED(hr)) {
    // Reached for a corrupt file, a missing file, and for any container with
    // no installed WIC codec (notably HEIC without the HEIF Image Extensions
    // package). All three are honest failures, not crashes.
    return Fail("LOAD_FAILED", "Cannot read source");
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) {
    return Fail("LOAD_FAILED", "Cannot read image");
  }

  UINT width = 0;
  UINT height = 0;
  hr = frame->GetSize(&width, &height);
  if (FAILED(hr) || width == 0 || height == 0) {
    return Fail("LOAD_FAILED", "Image has no pixels");
  }

  ComPtr<IWICBitmapSource> source;
  source = frame;

  // targetSize is an honest cap on the long edge, never an upscale
  // (native_thumbnail_service.dart:6-11). max(width, height) is invariant
  // under the 90-degree rotations applied below, so scaling first is safe.
  const UINT longest_edge = (std::max)(width, height);
  if (target_size > 0 && longest_edge > static_cast<UINT>(target_size)) {
    const double scale =
        static_cast<double>(target_size) / static_cast<double>(longest_edge);
    const UINT scaled_width =
        (std::max)(1u, static_cast<UINT>(static_cast<double>(width) * scale + 0.5));
    const UINT scaled_height =
        (std::max)(1u, static_cast<UINT>(static_cast<double>(height) * scale + 0.5));
    ComPtr<IWICBitmapScaler> scaler;
    hr = factory->CreateBitmapScaler(&scaler);
    if (FAILED(hr)) {
      return Fail("CONVERT_FAILED", "Cannot create scaler");
    }
    hr = scaler->Initialize(source.Get(), scaled_width, scaled_height,
                            WICBitmapInterpolationModeFant);
    if (FAILED(hr)) {
      return Fail("CONVERT_FAILED", "Cannot scale image");
    }
    source = scaler;
  }

  // The re-encoded JPEG carries no EXIF block, so it has no Orientation tag
  // for Flutter to honour. The rotation must therefore be baked into the
  // pixels here -- this is the counterpart of macOS's
  // kCGImageSourceCreateThumbnailWithTransform (AppDelegate.swift:432,482)
  // and of the export path forcing Orientation=1.
  const unsigned int orientation = ReadExifOrientation(frame.Get());
  if (orientation != 1) {
    ComPtr<IWICBitmapFlipRotator> rotator;
    if (SUCCEEDED(factory->CreateBitmapFlipRotator(&rotator)) &&
        SUCCEEDED(rotator->Initialize(source.Get(),
                                      TransformForOrientation(orientation)))) {
      source = rotator;
    }
    // A failed rotate is deliberately non-fatal: a correctly-sized but
    // unrotated image is a better outcome than no image at all.
  }

  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) {
    return Fail("CONVERT_FAILED", "Cannot create format converter");
  }
  hr = converter->Initialize(source.Get(), GUID_WICPixelFormat24bppBGR,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return Fail("CONVERT_FAILED", "Cannot convert pixel format");
  }

  ImageResult result;
  if (FAILED(EncodeJpeg(factory.Get(), converter.Get(), &result.bytes))) {
    return Fail("CONVERT_FAILED", "Cannot encode JPEG");
  }
  result.ok = true;
  return result;
}

}  // namespace

bool IsRawExtension(const std::string& lowercase_utf8_path) {
  static const char* const kRawExtensions[] = {".dng", ".arw", ".cr2",
                                               ".nef", ".orf", ".rw2"};
  for (const char* extension : kRawExtensions) {
    if (HasSuffix(lowercase_utf8_path, extension)) {
      return true;
    }
  }
  return false;
}

ImageResult RequestImage(const std::string& utf8_path,
                         const std::string& purpose,
                         int target_size) {
  const std::wstring path = Utf16FromUtf8(utf8_path);
  if (path.empty()) {
    return Fail("INVALID_ARGS", "Path is empty or not valid UTF-8");
  }
  const std::string lowered = LowerAscii(utf8_path);

  if (IsRawExtension(lowered)) {
    // AC2. Windows ships without RAW this round: there is no Windows build of
    // the native decoder (docs/logs/2026-08-21/premise-audit-platforms.md), so
    // this returns a plain failure and NOT kNoEmbeddedPreviewCode
    // ("NO_EMBEDDED_PREVIEW"). That distinction is the whole point: the
    // NO_EMBEDDED_PREVIEW code makes Dart construct NativeImageNeedsRawDecode
    // (native_thumbnail_service.dart:115-119) and go looking for a
    // DngFullDecoder, whereas any other code maps to NativeImageFailure
    // (native_thumbnail_service.dart:120-121) -- a clean "no image available".
    return Fail("RAW_UNSUPPORTED",
                "RAW and DNG decoding is not available on Windows");
  }

  // Mirror of the macOS JPEG passthrough (AppDelegate.swift:360-370): a
  // full-size preview of a JPEG returns the original file bytes, skipping a
  // pointless decode plus re-encode. No rotation is applied here on purpose --
  // these bytes still carry their EXIF block, and Flutter's Image.memory
  // honours EXIF orientation for JPEG.
  if (purpose == "preview" &&
      (HasSuffix(lowered, ".jpg") || HasSuffix(lowered, ".jpeg"))) {
    ImageResult result;
    if (!ReadWholeFile(path, &result.bytes) || result.bytes.empty()) {
      return Fail("LOAD_FAILED", "Cannot read image");
    }
    result.ok = true;
    return result;
  }

  return DecodeAndReencode(path,
                           target_size > 0 ? target_size : kDefaultTargetSize);
}

}  // namespace halcyon
