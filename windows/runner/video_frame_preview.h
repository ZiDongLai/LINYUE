#ifndef RUNNER_LINYUE_VIDEO_FRAME_PREVIEW_H_
#define RUNNER_LINYUE_VIDEO_FRAME_PREVIEW_H_

// E20-C3B: Windows Explorer video frame thumbnails, display-only.
// Uses the installed Windows thumbnail provider. No ffmpeg/downloads,
// no writes to or mutation of the original video, never a fake video frame.
// Kept header-only to preserve the tested windows/runner/CMakeLists.txt.

#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "windowscodecs.lib")

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <thread>
#include <cstdint>
#include <cwctype>
#include <memory>
#include <string>
#include <vector>

namespace linyue_video_preview {
using Microsoft::WRL::ComPtr;
// Do not block Flutter's Windows UI thread on Shell thumbnail decoding.
inline std::mutex reply_mutex;
inline std::atomic<bool> allow_replies{false};
inline std::atomic<int> active_jobs{0};

inline void Shutdown() {
  // The runner calls this before disposing the Flutter engine/messenger.
  std::lock_guard<std::mutex> guard(reply_mutex);
  allow_replies.store(false);
}


inline bool Utf8Path(const std::string& value, std::wstring* out) {
  if (value.empty() || value.find('\0') != std::string::npos) return false;
  const int len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.c_str(), -1, nullptr, 0);
  if (len <= 1 || len > 32768) return false;
  std::wstring temp(static_cast<size_t>(len), L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(),
                          -1, temp.data(), len)) return false;
  temp.resize(static_cast<size_t>(len - 1));
  *out = std::move(temp);
  return true;
}

inline bool IsVideoName(const std::wstring& path) {
  const auto end = path.rfind(L'.');
  if (end == std::wstring::npos) return false;
  std::wstring extension = path.substr(end);
  std::transform(extension.begin(), extension.end(), extension.begin(),
      [](wchar_t ch) { return static_cast<wchar_t>(towlower(ch)); });
  return extension == L".mp4" || extension == L".m4v" || extension == L".mov" ||
      extension == L".3gp" || extension == L".3g2" || extension == L".webm" ||
      extension == L".mkv" || extension == L".avi" || extension == L".wmv" ||
      extension == L".mpg" || extension == L".mpeg";
}

inline bool IsValidOriginal(const std::wstring& path) {
  if (!IsVideoName(path)) return false;
  const HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info = {};
  const bool ok = GetFileInformationByHandle(file, &info) &&
      !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
  const uint64_t size = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) |
                        static_cast<uint64_t>(info.nFileSizeLow);
  CloseHandle(file);
  return ok && size > 0 && size <= (1024ULL * 1024ULL * 1024ULL);
}

inline std::vector<uint8_t> ReadNativeFrame(const std::wstring& path) {
  if (!IsValidOriginal(path)) return {};
  const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool did_init = SUCCEEDED(init);
  // COM already initialized as another model: do not uninitialize it.
  std::vector<uint8_t> bytes;
  do {
    ComPtr<IShellItemImageFactory> image_factory;
    const HRESULT shell_result = SHCreateItemFromParsingName(
        path.c_str(), nullptr, IID_PPV_ARGS(image_factory.GetAddressOf()));
    if (FAILED(shell_result)) break;

    HBITMAP frame = nullptr;
    const SIZE size = {360, 360};
    // THUMBNAILONLY forbids returning a normal file icon as a fake video frame.
    const HRESULT image_result = image_factory->GetImage(size,
        static_cast<SIIGBF>(SIIGBF_THUMBNAILONLY | SIIGBF_RESIZETOFIT), &frame);
    if (FAILED(image_result) || !frame) break;

    // An HBITMAP is converted to a small PNG in memory using the OS WIC codec.
    // No temporary file is written to the receive directory or elsewhere.
    do {
      ComPtr<IWICImagingFactory> factory;
      if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
          CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.GetAddressOf())))) break;
      ComPtr<IWICBitmap> bitmap;
      if (FAILED(factory->CreateBitmapFromHBITMAP(
          frame, nullptr, WICBitmapIgnoreAlpha, bitmap.GetAddressOf()))) break;
      UINT width = 0, height = 0;
      if (FAILED(bitmap->GetSize(&width, &height)) || !width || !height ||
          width > 720 || height > 720) break;

      ComPtr<IStream> stream;
      if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, stream.GetAddressOf()))) break;
      ComPtr<IWICBitmapEncoder> encoder;
      if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng,
          nullptr, encoder.GetAddressOf()))) break;
      if (FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) break;
      ComPtr<IWICBitmapFrameEncode> writer;
      ComPtr<IPropertyBag2> props;
      if (FAILED(encoder->CreateNewFrame(writer.GetAddressOf(), props.GetAddressOf()))) break;
      if (FAILED(writer->Initialize(props.Get()))) break;
      if (FAILED(writer->SetSize(width, height))) break;
      WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
      if (FAILED(writer->SetPixelFormat(&format))) break;
      if (FAILED(writer->WriteSource(bitmap.Get(), nullptr))) break;
      if (FAILED(writer->Commit()) || FAILED(encoder->Commit())) break;

      HGLOBAL memory = nullptr;
      if (FAILED(GetHGlobalFromStream(stream.Get(), &memory)) || !memory) break;
      STATSTG info = {};
      if (FAILED(stream->Stat(&info, STATFLAG_NONAME))) break;
      if (info.cbSize.QuadPart == 0 || info.cbSize.QuadPart > (2 * 1024 * 1024)) break;
      const SIZE_T length = static_cast<SIZE_T>(info.cbSize.QuadPart);
      const auto* data = static_cast<const uint8_t*>(GlobalLock(memory));
      if (data) {
        bytes.assign(data, data + length);
        GlobalUnlock(memory);
      }
    } while (false);
    DeleteObject(frame);
  } while (false);
  if (did_init) CoUninitialize();
  return bytes;
}

inline std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
Register(flutter::FlutterEngine* engine) {
  {
    std::lock_guard<std::mutex> guard(reply_mutex);
    allow_replies.store(true);
  }
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "linyue/video_thumbnail",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> reply) {
    if (call.method_name() != "extractPreview") {
      reply->NotImplemented();
      return;
    }
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!args) { reply->Success(flutter::EncodableValue()); return; }
    const auto at = args->find(flutter::EncodableValue("path"));
    if (at == args->end()) {
      reply->Success(flutter::EncodableValue()); return;
    }
    const auto* raw = std::get_if<std::string>(&at->second);
    std::wstring path;
    if (!raw || !Utf8Path(*raw, &path)) {
      reply->Success(flutter::EncodableValue()); return;
    }
    // Limit native decoders and return immediately to the Flutter UI loop.
    // Under heavy load excess requests gracefully show the generic poster.
    if (active_jobs.fetch_add(1) >= 8) {
      active_jobs.fetch_sub(1);
      reply->Success(flutter::EncodableValue());
      return;
    }
    try {
      std::thread([path = std::move(path), reply = std::move(reply)]() mutable {
        std::vector<uint8_t> bytes;
        try { bytes = ReadNativeFrame(path); } catch (...) { bytes.clear(); }
        {
          // Shutdown serializes with replies before the engine is destroyed.
          std::lock_guard<std::mutex> guard(reply_mutex);
          if (allow_replies.load()) {
            if (bytes.empty()) reply->Success(flutter::EncodableValue());
            else reply->Success(flutter::EncodableValue(std::move(bytes)));
          }
        }
        active_jobs.fetch_sub(1);
      }).detach();
    } catch (...) {
      active_jobs.fetch_sub(1);
      reply->Success(flutter::EncodableValue());
    }
  });
  return channel;
}

}  // namespace linyue_video_preview

#endif  // RUNNER_LINYUE_VIDEO_FRAME_PREVIEW_H_
