#include "disk_capacity_channel.h"

#include <windows.h>

#include <cstdint>
#include <limits>
#include <string>

#include <flutter/standard_method_codec.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

bool Utf8PathToWide(const std::string& path, std::wstring* wide_path) {
  if (path.empty() || path.find('\0') != std::string::npos ||
      path.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  const int required = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), static_cast<int>(path.size()),
      nullptr, 0);
  if (required <= 0) return false;

  wide_path->resize(required);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(),
                             static_cast<int>(path.size()), wide_path->data(),
                             required) == required;
}

void HandleAvailableBytes(
    const MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (call.method_name() != "availableBytes") {
    result->NotImplemented();
    return;
  }

  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("INVALID_ARGUMENTS", "Expected a map containing a path");
    return;
  }
  const auto path_it = arguments->find(EncodableValue("path"));
  if (path_it == arguments->end() ||
      !std::holds_alternative<std::string>(path_it->second)) {
    result->Error("INVALID_ARGUMENTS", "Missing destination path");
    return;
  }

  std::wstring wide_path;
  if (!Utf8PathToWide(std::get<std::string>(path_it->second), &wide_path)) {
    result->Error("INVALID_PATH", "Destination path is not valid UTF-8");
    return;
  }

  ULARGE_INTEGER available_to_caller = {};
  if (!GetDiskFreeSpaceExW(wide_path.c_str(), &available_to_caller, nullptr,
                           nullptr)) {
    const DWORD error = GetLastError();
    result->Error("DISK_SPACE_QUERY_FAILED",
                  "GetDiskFreeSpaceExW failed (Win32 error " +
                      std::to_string(error) + ")");
    return;
  }
  if (available_to_caller.QuadPart >
      static_cast<ULONGLONG>(std::numeric_limits<int64_t>::max())) {
    result->Error("DISK_SPACE_OUT_OF_RANGE",
                  "Available space exceeds the supported integer range");
    return;
  }

  result->Success(EncodableValue(
      static_cast<int64_t>(available_to_caller.QuadPart)));
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterDiskCapacityChannel(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "nearlink/disk_capacity",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(HandleAvailableBytes);
  return channel;
}
