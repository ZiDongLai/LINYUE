#ifndef RUNNER_LINYUE_MINI_CHAT_WINDOW_CONTROL_H_
#define RUNNER_LINYUE_MINI_CHAT_WINDOW_CONTROL_H_

// E21-C1: one existing HWND and Flutter engine. Window geometry is reported
// to Dart, which keeps only non-sensitive UI preferences in app support.
// No second pairing, listener, database, or file queue is ever created.
#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <string>

namespace linyue_mini_window {

using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodChannel;
using flutter::MethodResult;

struct MiniWindowState {
  WINDOWPLACEMENT original_placement{};
  bool original_topmost = false;
  bool mini = false;
  bool pinned = false;
  std::string size_preset = "medium";
};

inline int Clamp(int v, int lo, int hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

inline bool ReadInteger(const flutter::EncodableMap& args,
                        const char* key, int* output) {
  const auto it = args.find(EncodableValue(std::string(key)));
  if (it == args.end()) return false;
  if (const auto* v = std::get_if<int32_t>(&it->second)) {
    *output = static_cast<int>(*v);
    return true;
  }
  if (const auto* v = std::get_if<int64_t>(&it->second)) {
    if (*v < -1000000 || *v > 1000000) return false;
    *output = static_cast<int>(*v);
    return true;
  }
  return false;
}

inline std::string ReadPreset(const flutter::EncodableMap* args,
                              const std::string& fallback) {
  if (!args) return fallback;
  const auto it = args->find(EncodableValue("preset"));
  if (it == args->end()) return fallback;
  const auto* str = std::get_if<std::string>(&it->second);
  if (!str) return fallback;
  if (*str == "small" || *str == "medium" || *str == "large") return *str;
  return fallback;
}

inline bool ReadSavedRectangle(const flutter::EncodableMap* args, RECT* rect) {
  if (!args) return false;
  int x = 0, y = 0, width = 0, height = 0;
  if (!ReadInteger(*args, "x", &x) || !ReadInteger(*args, "y", &y) ||
      !ReadInteger(*args, "width", &width) ||
      !ReadInteger(*args, "height", &height)) return false;
  if (width < 300 || width > 3000 || height < 330 || height > 3000) return false;
  rect->left = x;
  rect->top = y;
  rect->right = x + width;
  rect->bottom = y + height;
  return true;
}

inline void PresetDimensions(const std::string& preset, UINT dpi,
                            int* width, int* height) {
  int logical_width = 450, logical_height = 680;
  if (preset == "small") { logical_width = 370; logical_height = 560; }
  if (preset == "large") { logical_width = 560; logical_height = 780; }
  const int actual_dpi = static_cast<int>(dpi ? dpi : 96);
  *width = MulDiv(logical_width, actual_dpi, 96);
  *height = MulDiv(logical_height, actual_dpi, 96);
}

// Keep at least the full mini window on a currently connected monitor. A
// disconnected secondary display can never strand the window off-screen.
inline bool ClampToVisibleWorkArea(RECT* requested) {
  const HMONITOR nearest = MonitorFromRect(requested, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(nearest, &info)) return false;
  const RECT area = info.rcWork;
  const int available_w = area.right - area.left;
  const int available_h = area.bottom - area.top;
  if (available_w < 330 || available_h < 340) return false;
  const int width = Clamp(requested->right - requested->left, 320, available_w);
  const int height = Clamp(requested->bottom - requested->top, 340, available_h);
  const int x = Clamp(requested->left, area.left, area.right - width);
  const int y = Clamp(requested->top, area.top, area.bottom - height);
  *requested = RECT{x, y, x + width, y + height};
  return true;
}

inline bool Enter(HWND hwnd, MiniWindowState& state,
                  const flutter::EncodableMap* args) {
  if (!IsWindow(hwnd)) return false;
  if (state.mini) return true;
  state.original_placement.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(hwnd, &state.original_placement)) return false;
  state.original_topmost =
      (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;

  const std::string preset = ReadPreset(args, "medium");
  int width = 0, height = 0;
  PresetDimensions(preset, GetDpiForWindow(hwnd), &width, &height);
  const HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return false;
  const RECT area = info.rcWork;
  RECT desired{area.right - width - 18, area.top + 35,
               area.right - 18, area.top + 35 + height};
  // A previously saved rectangle takes priority if valid. The Dart side
  // provides it only for the same preset, not for another size tier.
  RECT saved{};
  if (ReadSavedRectangle(args, &saved)) desired = saved;
  if (!ClampToVisibleWorkArea(&desired)) return false;

  ShowWindow(hwnd, SW_RESTORE);
  if (!SetWindowPos(hwnd, HWND_TOP,
                    desired.left, desired.top,
                    desired.right - desired.left,
                    desired.bottom - desired.top,
                    SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
    SetWindowPlacement(hwnd, &state.original_placement);
    return false;
  }
  state.mini = true;
  state.pinned = false;
  state.size_preset = preset;
  return true;
}

inline bool SetPinned(HWND hwnd, MiniWindowState& state, bool value) {
  if (!state.mini || !IsWindow(hwnd)) return false;
  if (!SetWindowPos(hwnd, value ? HWND_TOPMOST : HWND_NOTOPMOST,
                    0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) return false;
  state.pinned = value;
  return true;
}

inline bool SetSize(HWND hwnd, MiniWindowState& state,
                    const std::string& preset) {
  if (!state.mini || !IsWindow(hwnd)) return false;
  RECT current{};
  if (!GetWindowRect(hwnd, &current)) return false;
  int width = 0, height = 0;
  PresetDimensions(preset, GetDpiForWindow(hwnd), &width, &height);
  RECT desired{current.left, current.top,
               current.left + width, current.top + height};
  if (!ClampToVisibleWorkArea(&desired)) return false;
  if (!SetWindowPos(hwnd, nullptr,
                    desired.left, desired.top,
                    desired.right - desired.left,
                    desired.bottom - desired.top,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) return false;
  state.size_preset = preset;
  return true;
}

inline bool Restore(HWND hwnd, MiniWindowState& state) {
  if (!IsWindow(hwnd)) return false;
  if (!state.mini) return true;
  if (!SetWindowPos(hwnd,
      state.original_topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
      0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) return false;
  WINDOWPLACEMENT placement = state.original_placement;
  placement.length = sizeof(WINDOWPLACEMENT);
  if (!SetWindowPlacement(hwnd, &placement)) return false;
  state.mini = false;
  state.pinned = false;
  return true;
}

inline flutter::EncodableMap Snapshot(HWND hwnd, const MiniWindowState& state) {
  flutter::EncodableMap data;
  data[EncodableValue("mini")] = EncodableValue(state.mini);
  data[EncodableValue("pinned")] = EncodableValue(state.pinned);
  data[EncodableValue("preset")] = EncodableValue(state.size_preset);
  RECT rect{};
  // Do not persist the offscreen (-32000, -32000) coordinates of a
  // minimized Windows HWND as the user's intended floating position.
  if (state.mini && !IsIconic(hwnd) && GetWindowRect(hwnd, &rect)) {
    data[EncodableValue("x")] = EncodableValue(static_cast<int32_t>(rect.left));
    data[EncodableValue("y")] = EncodableValue(static_cast<int32_t>(rect.top));
    data[EncodableValue("width")] = EncodableValue(static_cast<int32_t>(rect.right - rect.left));
    data[EncodableValue("height")] = EncodableValue(static_cast<int32_t>(rect.bottom - rect.top));
  }
  return data;
}

inline std::unique_ptr<MethodChannel<EncodableValue>> Register(
    flutter::FlutterEngine* engine, HWND hwnd) {
  if (!engine || !IsWindow(hwnd)) return nullptr;
  auto channel = std::make_unique<MethodChannel<EncodableValue>>(
      engine->messenger(), "nearlink/mini_window",
      &flutter::StandardMethodCodec::GetInstance());
  auto state = std::make_shared<MiniWindowState>();
  channel->SetMethodCallHandler(
      [state, hwnd](const MethodCall<EncodableValue>& call,
                    std::unique_ptr<MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        const flutter::EncodableMap* args = nullptr;
        if (call.arguments()) args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (method == "enterMini") {
          result->Success(EncodableValue(Enter(hwnd, *state, args)));
          return;
        }
        if (method == "restoreMain") {
          result->Success(EncodableValue(Restore(hwnd, *state)));
          return;
        }
        if (method == "setTopmost") {
          if (!args) {
            result->Success(EncodableValue(false)); return;
          }
          const auto it = args->find(EncodableValue("enabled"));
          if (it == args->end()) {
            result->Success(EncodableValue(false)); return;
          }
          const auto* enabled = std::get_if<bool>(&it->second);
          // E21-C1: false must invoke HWND_NOTOPMOST, not short-circuit.
          result->Success(EncodableValue(enabled != nullptr &&
              SetPinned(hwnd, *state, *enabled)));
          return;
        }
        if (method == "resizeMini") {
          const std::string preset = ReadPreset(args, "");
          result->Success(EncodableValue(!preset.empty() &&
              SetSize(hwnd, *state, preset)));
          return;
        }
        if (method == "getMiniState") {
          result->Success(EncodableValue(Snapshot(hwnd, *state)));
          return;
        }
        result->NotImplemented();
      });
  return channel;
}
}  // namespace linyue_mini_window

#endif  // RUNNER_LINYUE_MINI_CHAT_WINDOW_CONTROL_H_
