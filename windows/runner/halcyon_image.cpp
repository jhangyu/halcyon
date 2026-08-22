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
// wincodecsdk.h, not wincodec.h, is where the metadata WRITE surface lives:
// IWICMetadataBlockReader / IWICMetadataBlockWriter / IWICMetadataQueryWriter.
// (IWICMetadataQueryReader, used by ReadExifOrientation below, is the one
// metadata interface that wincodec.h does declare.) It needs no extra .lib:
// the interfaces are reached through IID_PPV_ARGS / __uuidof, so no IID_*
// symbol is referenced and windowscodecs.lib -- already linked in
// windows/runner/CMakeLists.txt:51 -- remains sufficient.
#include <wincodecsdk.h>
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

// Rewrites a metadata tag that is ALREADY present, and never creates one.
// GetMetadataByName is used purely as an existence probe: a source whose Exif
// sub-IFD does not exist must not gain a synthetic one holding nothing but the
// two pixel-dimension tags. IWICMetadataQueryWriter derives from
// IWICMetadataQueryReader, so the probe and the write go through one object.
void OverwriteExistingUint(IWICMetadataQueryWriter* writer,
                           const wchar_t* query,
                           UINT new_value) {
  PROPVARIANT probe;
  ::PropVariantInit(&probe);
  const bool present = SUCCEEDED(writer->GetMetadataByName(query, &probe)) &&
                       probe.vt != VT_EMPTY;
  ::PropVariantClear(&probe);
  if (!present) {
    return;
  }
  PROPVARIANT value;
  ::PropVariantInit(&value);
  // EXIF permits SHORT or LONG for tags 40962/40963; VT_UI4 asks WIC for LONG,
  // which is in-spec for either source encoding.
  value.vt = VT_UI4;
  value.ulVal = new_value;
  (void)writer->SetMetadataByName(query, &value);
  ::PropVariantClear(&value);
}

// Copies the source frame's metadata blocks (EXIF / GPS / IPTC / XMP) onto the
// encoder frame, then forces Orientation to 1. This is the Windows counterpart
// of AppDelegate.swift:250-278, and exists ONLY for the `export` purpose --
// see the |metadata_source| gate in EncodeJpeg.
//
// EVERY step is deliberately non-fatal, in the same spirit as the ImageQuality
// write below: a source with no metadata at all, or a codec that refuses
// IWICMetadataBlockWriter, must still yield a valid JPEG. An export that began
// FAILING because metadata could not be copied would be a worse defect than
// the metadata loss this fixes.
//
// Orientation is WRITTEN AS 1, never carried over. The pixels handed to the
// encoder have already been rotated by DecodeAndReencode's flip-rotator, so a
// surviving source Orientation would make every viewer rotate a second time.
// macOS writes 1 into two places -- the top-level property and the TIFF
// sub-dictionary (AppDelegate.swift:266,271) -- but those are two ImageIO
// VIEWS of one underlying tag, EXIF IFD0 tag 274. WIC exposes no such
// duplication: in a JPEG container there is exactly one App1/IFD0 274, and it
// is the query written below (the write form of ReadExifOrientation's first
// query; the `/ifd/...` alternative there is the TIFF-container spelling and
// cannot apply, since this encoder is always GUID_ContainerFormatJpeg).
//
// The one real duplicate on Windows is XMP `tiff:Orientation`, which Adobe
// tooling may prefer over EXIF. It is REMOVED rather than rewritten, because
// removing it makes viewers fall back to the EXIF 1 we just wrote, whereas
// writing it would mean guessing XMP's value encoding. RemoveMetadataByName
// returning "not found" is the normal case and is ignored.
//
// ponytail: block-level copy is all this does -- there is no per-tag scrub, so
// anything the source carried (GPS coordinates, serial numbers, maker notes)
// is carried over verbatim, exactly as macOS does. If privacy-stripping is
// ever wanted, it belongs here as an explicit RemoveMetadataByName list, not
// as a switch to hand-rolled EXIF serialisation.
void CopySourceMetadata(IWICBitmapFrameDecode* source_frame,
                        IWICBitmapFrameEncode* encoder_frame,
                        UINT encoded_width,
                        UINT encoded_height) {
  ComPtr<IWICMetadataBlockReader> block_reader;
  if (FAILED(source_frame->QueryInterface(IID_PPV_ARGS(&block_reader)))) {
    return;
  }
  ComPtr<IWICMetadataBlockWriter> block_writer;
  if (FAILED(encoder_frame->QueryInterface(IID_PPV_ARGS(&block_writer)))) {
    return;
  }
  // Must happen after IWICBitmapFrameEncode::Initialize and before Commit;
  // this is the ordering of the documented "re-encode a JPEG with metadata"
  // sequence (Initialize -> InitializeFromBlockReader -> WriteSource ->
  // Commit), which the call site preserves.
  if (FAILED(block_writer->InitializeFromBlockReader(block_reader.Get()))) {
    return;
  }

  ComPtr<IWICMetadataQueryWriter> writer;
  if (FAILED(encoder_frame->GetMetadataQueryWriter(&writer)) || !writer) {
    // The blocks copied above still land in the output; only the Orientation
    // override is lost. That combination WOULD double-rotate, so it is called
    // out in the verification protocol
    // (docs/logs/2026-08-22/windows-export-exif-verification.md) as the
    // signature to look for if exported images come out sideways.
    return;
  }

  PROPVARIANT orientation;
  ::PropVariantInit(&orientation);
  orientation.vt = VT_UI2;  // EXIF SHORT, matching ReadExifOrientation's read.
  orientation.uiVal = 1;
  (void)writer->SetMetadataByName(L"/app1/ifd/{ushort=274}", &orientation);
  ::PropVariantClear(&orientation);

  (void)writer->RemoveMetadataByName(L"/xmp/tiff:Orientation");

  // The Exif pixel-dimension tags describe the ORIGINAL frame; leaving them at
  // the source values makes the file self-contradictory after a downscale.
  // Same reasoning as AppDelegate.swift:272-276.
  OverwriteExistingUint(writer.Get(), L"/app1/ifd/exif/{ushort=40962}",
                        encoded_width);
  OverwriteExistingUint(writer.Get(), L"/app1/ifd/exif/{ushort=40963}",
                        encoded_height);
}

// |metadata_source| is the decoder frame whose metadata should be copied into
// the output, or nullptr to write no metadata at all (the pre-existing
// behaviour, still used by every non-export purpose).
HRESULT EncodeJpeg(IWICImagingFactory* factory,
                   IWICBitmapSource* source,
                   IWICBitmapFrameDecode* metadata_source,
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

  // Export parity with macOS: carry the source's EXIF across, Orientation
  // forced to 1. nullptr for every other purpose, so the preview and
  // sidebarThumbnail paths reach Commit having touched no metadata interface
  // at all -- byte-for-byte the previous behaviour.
  if (metadata_source != nullptr) {
    CopySourceMetadata(metadata_source, frame.Get(), width, height);
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

// |copy_metadata| is true only for the `export` purpose; see RequestImage.
ImageResult DecodeAndReencode(const std::wstring& path,
                              int target_size,
                              bool copy_metadata) {
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

  // The rotation is baked into the PIXELS here, for both metadata modes, and
  // this must stay that way:
  //   - !copy_metadata: the re-encoded JPEG carries no EXIF block at all, so
  //     there is no Orientation tag left for Flutter to honour.
  //   - copy_metadata (export): the EXIF block survives, but CopySourceMetadata
  //     overwrites its Orientation with 1 precisely because the pixels are
  //     already rotated.
  // This is the counterpart of macOS's kCGImageSourceCreateThumbnailWithTransform
  // (AppDelegate.swift:432,482) and of the export path forcing Orientation=1.
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
  if (FAILED(EncodeJpeg(factory.Get(), converter.Get(),
                        copy_metadata ? frame.Get() : nullptr,
                        &result.bytes))) {
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

  // The EXIF carry-over is gated HERE, on the purpose string, and nowhere
  // else. `sidebarThumbnail` and `preview` reach DecodeAndReencode with
  // copy_metadata == false, which makes EncodeJpeg's |metadata_source| null,
  // which makes CopySourceMetadata unreachable for them -- their output is
  // byte-for-byte what it was before the export fix.
  // ImageRequestPurpose.export.platformValue is the literal "export"
  // (native_thumbnail_service.dart:18); a purpose string this runner does not
  // recognise (or an omitted one, defaulted to "preview" by
  // halcyon_channels.cpp:87-88) therefore degrades to the no-metadata path.
  const bool is_export = purpose == "export";
  return DecodeAndReencode(path,
                           target_size > 0 ? target_size : kDefaultTargetSize,
                           is_export);
}

}  // namespace halcyon
