#pragma once
#include <cstddef>
namespace linyue_bluetooth {
constexpr size_t kBluetoothQueueBytes=65536;
constexpr size_t kBluetoothTotalFrameBytes=16384;
inline bool CanQueueBluetoothBytes(size_t queued,size_t length) {
  return length>0 && length<=kBluetoothTotalFrameBytes &&
      queued<=kBluetoothQueueBytes && length<=kBluetoothQueueBytes-queued;
}
}
