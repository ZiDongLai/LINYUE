#ifndef RUNNER_DISK_CAPACITY_CHANNEL_H_
#define RUNNER_DISK_CAPACITY_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterDiskCapacityChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_DISK_CAPACITY_CHANNEL_H_
