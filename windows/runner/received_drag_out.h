#ifndef RUNNER_RECEIVED_DRAG_OUT_H_
#define RUNNER_RECEIVED_DRAG_OUT_H_

// DEV13D2E20-B. Windows Shell CF_HDROP drag source, COPY-only.
// Header-only implementation avoids changes to the existing runner CMake target.
// No file deletion, rename, or destination writes occur in this module.

#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <Shlobj.h>  // DROPFILES (Windows Shell CF_HDROP)
#pragma comment(lib, "ole32.lib")
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>

namespace linyue_drag_out {

inline bool Utf8ToWide(const std::string& value, std::wstring* output) {
  if (value.empty() || value.find('\0') != std::string::npos) return false;
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                  value.c_str(), -1, nullptr, 0);
  if (count <= 1) return false;
  std::wstring buf(static_cast<size_t>(count), L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                           value.c_str(), -1, &buf[0], count)) return false;
  buf.resize(static_cast<size_t>(count - 1));
  *output = std::move(buf);
  return true;
}

inline std::wstring RealPath(HANDLE handle) {
  const DWORD count = GetFinalPathNameByHandleW(handle, nullptr, 0,
                                                FILE_NAME_NORMALIZED);
  if (!count || count > 32768) return L"";
  std::wstring path(static_cast<size_t>(count + 1), L'\0');
  const DWORD result = GetFinalPathNameByHandleW(
      handle, &path[0], count + 1, FILE_NAME_NORMALIZED);
  if (!result || result > count) return L"";
  path.resize(result);
  return path;
}

inline bool CaseEqualPrefix(const std::wstring& text,
                            const std::wstring& prefix) {
  if (text.size() <= prefix.size()) return false;
  return CompareStringOrdinal(text.data(), static_cast<int>(prefix.size()),
                              prefix.data(), static_cast<int>(prefix.size()),
                              TRUE) == CSTR_EQUAL;
}

inline bool ValidateReceivedFile(const std::wstring& path,
                                 const std::wstring& root,
                                 int64_t expected_bytes,
                                 std::wstring* canonical_file) {
  if (expected_bytes < 0 || path.empty() || root.empty()) return false;
  HANDLE directory = CreateFileW(root.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (directory == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION dir_info{};
  const bool valid_directory = GetFileInformationByHandle(directory, &dir_info) &&
      (dir_info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
  const auto canonical_root = valid_directory ? RealPath(directory) : L"";
  CloseHandle(directory);
  if (canonical_root.empty()) return false;

  HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info{};
  LARGE_INTEGER size{};
  const bool valid_file = GetFileInformationByHandle(file, &info) &&
      !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
      !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
      GetFileSizeEx(file, &size) && size.QuadPart == expected_bytes;
  const auto actual_path = valid_file ? RealPath(file) : L"";
  CloseHandle(file);
  if (actual_path.empty()) return false;

  std::wstring prefix = canonical_root;
  if (prefix.back() != L'\\') prefix.push_back(L'\\');
  if (!CaseEqualPrefix(actual_path, prefix)) return false;
  // CF_HDROP consumers commonly expect conventional Win32 paths. Retain
  // extended-length form for genuinely long paths.
  if (actual_path.size() < MAX_PATH &&
      actual_path.compare(0, 4, L"\\\\?\\") == 0) {
    if (actual_path.compare(0, 8, L"\\\\?\\UNC\\") == 0) {
      *canonical_file = L"\\\\" + actual_path.substr(8);
    } else {
      *canonical_file = actual_path.substr(4);
    }
  } else {
    *canonical_file = actual_path;
  }
  return true;
}

class SingleFormatEnumerator final : public IEnumFORMATETC {
 public:
  explicit SingleFormatEnumerator(ULONG index = 0) : index_(index) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** result) override {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (IsEqualIID(id, IID_IUnknown) || IsEqualIID(id, IID_IEnumFORMATETC)) {
      *result = static_cast<IEnumFORMATETC*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG count = --refs_;
    if (!count) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE Next(ULONG n, FORMATETC* out, ULONG* fetched) override {
    if (!out || (n != 1 && !fetched)) return E_POINTER;
    if (fetched) *fetched = 0;
    if (!n) return S_OK;
    if (index_ != 0) return S_FALSE;
    out[0] = FORMATETC{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    index_ = 1;
    if (fetched) *fetched = 1;
    return n == 1 ? S_OK : S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE Skip(ULONG n) override {
    if (n == 0) return S_OK;
    bool available = index_ == 0;
    index_ = 1;
    return available && n == 1 ? S_OK : S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE Reset() override { index_ = 0; return S_OK; }
  HRESULT STDMETHODCALLTYPE Clone(IEnumFORMATETC** output) override {
    if (!output) return E_POINTER;
    *output = new SingleFormatEnumerator(index_);
    return S_OK;
  }
 private:
  std::atomic<ULONG> refs_{1};
  ULONG index_ = 0;
};

class ReceivedFileDataObject final : public IDataObject {
 public:
  explicit ReceivedFileDataObject(std::wstring path) : path_(std::move(path)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** result) override {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (IsEqualIID(id, IID_IUnknown) || IsEqualIID(id, IID_IDataObject)) {
      *result = static_cast<IDataObject*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG count = --refs_;
    if (!count) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* fmt) override {
    if (!fmt) return E_INVALIDARG;
    if (fmt->cfFormat != CF_HDROP) return DV_E_FORMATETC;
    if (!(fmt->tymed & TYMED_HGLOBAL)) return DV_E_TYMED;
    if (fmt->dwAspect != DVASPECT_CONTENT || fmt->lindex != -1) return DV_E_DVASPECT;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* fmt, STGMEDIUM* medium) override {
    if (!medium) return E_POINTER;
    const HRESULT allowed = QueryGetData(fmt);
    if (FAILED(allowed)) return allowed;
    const SIZE_T bytes = sizeof(DROPFILES) + (path_.size() + 2) * sizeof(wchar_t);
    HGLOBAL global = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
    if (!global) return E_OUTOFMEMORY;
    auto* drop = static_cast<DROPFILES*>(GlobalLock(global));
    if (!drop) { GlobalFree(global); return E_OUTOFMEMORY; }
    drop->pFiles = sizeof(DROPFILES);
    drop->fWide = TRUE;
    auto* names = reinterpret_cast<wchar_t*>(reinterpret_cast<BYTE*>(drop) + sizeof(DROPFILES));
    std::memcpy(names, path_.c_str(), (path_.size() + 1) * sizeof(wchar_t));
    GlobalUnlock(global);
    medium->tymed = TYMED_HGLOBAL;
    medium->hGlobal = global;
    medium->pUnkForRelease = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return DATA_E_FORMATETC; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC* out) override {
    if (out) out->ptd = nullptr;
    return DATA_S_SAMEFORMATETC;
  }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** output) override {
    if (!output) return E_POINTER;
    *output = nullptr;
    if (direction != DATADIR_GET) return E_NOTIMPL;
    *output = new SingleFormatEnumerator();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
 private:
  std::atomic<ULONG> refs_{1};
  std::wstring path_;
};

class CopyOnlyDragSource final : public IDropSource {
 public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** result) override {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (IsEqualIID(id, IID_IUnknown) || IsEqualIID(id, IID_IDropSource)) {
      *result = static_cast<IDropSource*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG count = --refs_;
    if (!count) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
    if (escape) return DRAGDROP_S_CANCEL;
    if (!(keys & MK_LBUTTON)) return DRAGDROP_S_DROP;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }
 private:
  std::atomic<ULONG> refs_{1};
};

inline std::string RunCopyDrag(const std::wstring& path,
                               const std::wstring& receive_root,
                               int64_t expected_bytes) {
  std::wstring verified_path;
  if (!ValidateReceivedFile(path, receive_root, expected_bytes, &verified_path)) {
    return "denied";
  }
  if (!(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) return "cancelled";
  const HRESULT init = OleInitialize(nullptr);
  if (FAILED(init)) return "ole_unavailable";
  auto* data = new ReceivedFileDataObject(std::move(verified_path));
  auto* source = new CopyOnlyDragSource();
  DWORD effect = DROPEFFECT_NONE;
  // Explicitly allow COPY only. No MOVE effect is ever offered to targets.
  const HRESULT result = DoDragDrop(data, source, DROPEFFECT_COPY, &effect);
  source->Release();
  data->Release();
  OleUninitialize();
  if (result == DRAGDROP_S_DROP && effect == DROPEFFECT_COPY) return "copied";
  if (result == DRAGDROP_S_CANCEL || effect == DROPEFFECT_NONE) return "cancelled";
  return "failed";
}

inline std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
Register(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "linyue/windows_received_drag_out",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> response) {
    if (call.method_name() != "startCopyDrag") {
      response->NotImplemented();
      return;
    }
    const auto* map = call.arguments()
                          ? std::get_if<flutter::EncodableMap>(call.arguments())
                          : nullptr;
    if (!map) { response->Error("invalid_args", "Expected map"); return; }
    const auto find_str = [map](const char* key) -> const std::string* {
      const auto it = map->find(flutter::EncodableValue(key));
      if (it == map->end()) return nullptr;
      return std::get_if<std::string>(&it->second);
    };
    const auto* raw_path = find_str("path");
    const auto* raw_root = find_str("root");
    const auto it_bytes = map->find(flutter::EncodableValue("bytes"));
    if (!raw_path || !raw_root || it_bytes == map->end()) {
      response->Error("invalid_args", "Missing drag parameters");
      return;
    }
    int64_t expected_bytes = -1;
    if (auto* wide = std::get_if<int64_t>(&it_bytes->second)) expected_bytes = *wide;
    if (auto* value32 = std::get_if<int32_t>(&it_bytes->second)) expected_bytes = *value32;
    std::wstring path, root;
    if (expected_bytes < 0 || !Utf8ToWide(*raw_path, &path) ||
        !Utf8ToWide(*raw_root, &root)) {
      response->Error("invalid_args", "Invalid path or size");
      return;
    }
    response->Success(flutter::EncodableValue(RunCopyDrag(path, root, expected_bytes)));
  });
  return channel;  // Owned by FlutterWindow until before engine shutdown.
}

}  // namespace linyue_drag_out
#endif  // RUNNER_RECEIVED_DRAG_OUT_H_
