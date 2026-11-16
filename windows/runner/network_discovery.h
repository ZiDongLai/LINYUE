#ifndef RUNNER_NETWORK_DISCOVERY_H_
#define RUNNER_NETWORK_DISCOVERY_H_

#include <flutter/engine_method_result.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterNetworkDiscovery(flutter::FlutterEngine* engine);

#endif  // RUNNER_NETWORK_DISCOVERY_H_
