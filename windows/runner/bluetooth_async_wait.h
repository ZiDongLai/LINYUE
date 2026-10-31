#pragma once
#include <chrono>
#include <thread>
#include <winrt/Windows.Foundation.h>

namespace linyue_bluetooth {
// IAsyncOperation::wait_for installs a Completed delegate on every call.
// Poll IAsyncInfo::Status instead; Completed may only be assigned once.
template<typename Async, typename Cancelled>
bool WaitForBluetoothOperation(const Async& operation, const Cancelled& cancelled,
    std::chrono::steady_clock::time_point deadline) {
  while (operation.Status()==winrt::Windows::Foundation::AsyncStatus::Started) {
    if (cancelled || std::chrono::steady_clock::now()>=deadline) {
      operation.Cancel(); return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  if (cancelled) { operation.Cancel(); return false; }
  return true; // Caller observes Completed/Error/Canceled using GetResults/get.
}
}
