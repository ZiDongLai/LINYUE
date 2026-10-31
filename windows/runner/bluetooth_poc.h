#ifndef LINYUE_BLUETOOTH_POC_H_
#define LINYUE_BLUETOOTH_POC_H_
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
namespace linyue_bluetooth {
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> Register(flutter::FlutterEngine* engine);
void Shutdown();
}
#endif
