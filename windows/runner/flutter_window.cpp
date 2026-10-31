#include "flutter_window.h"
#include "received_drag_out.h"
#include "video_frame_preview.h"
#include "mini_chat_window_control.h"
#ifndef NDEBUG
#include "bluetooth_poc.h"
#include "bluetooth_file_channel.h"
#endif

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
#ifndef NDEBUG
  bluetooth_poc_channel_ = linyue_bluetooth::Register(flutter_controller_->engine());
  bluetooth_file_channel_ = linyue_bt_file::RegisterFiles(flutter_controller_->engine()->messenger());
#endif
  drag_out_channel_ = linyue_drag_out::Register(flutter_controller_->engine());
  video_preview_channel_ = linyue_video_preview::Register(flutter_controller_->engine());
  mini_chat_window_channel_ = linyue_mini_window::Register(flutter_controller_->engine(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
#ifndef NDEBUG
  linyue_bluetooth::Shutdown();
  bluetooth_file_channel_.reset();
  bluetooth_poc_channel_.reset();
#endif
  linyue_video_preview::Shutdown();
  video_preview_channel_.reset();
  mini_chat_window_channel_.reset();
  drag_out_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
