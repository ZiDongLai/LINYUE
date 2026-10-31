#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;
#ifndef NDEBUG
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> bluetooth_poc_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> bluetooth_file_channel_;
#endif

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> drag_out_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> video_preview_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> mini_chat_window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
