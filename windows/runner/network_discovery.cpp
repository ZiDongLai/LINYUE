#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>

#include "network_discovery.h"

#include <array>
#include <vector>

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableList LocalIpv4Interfaces() {
  ULONG size = 16 * 1024;
  std::vector<BYTE> storage(size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
  ULONG status = GetAdaptersAddresses(
      AF_INET,
      GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
          GAA_FLAG_SKIP_DNS_SERVER,
      nullptr, adapters, &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    storage.resize(size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
    status = GetAdaptersAddresses(
        AF_INET,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
            GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, adapters, &size);
  }
  EncodableList result;
  if (status != NO_ERROR) return result;

  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) {
      continue;
    }
    for (auto* address = adapter->FirstUnicastAddress; address != nullptr;
         address = address->Next) {
      if (address->Address.lpSockaddr == nullptr ||
          address->Address.lpSockaddr->sa_family != AF_INET ||
          address->OnLinkPrefixLength > 32) {
        continue;
      }
      const auto* ipv4 = reinterpret_cast<const SOCKADDR_IN*>(
          address->Address.lpSockaddr);
      std::array<char, INET_ADDRSTRLEN> text{};
      if (InetNtopA(AF_INET, const_cast<IN_ADDR*>(&ipv4->sin_addr),
                    text.data(), static_cast<DWORD>(text.size())) == nullptr) {
        continue;
      }
      result.emplace_back(EncodableMap{
          {EncodableValue("address"), EncodableValue(std::string(text.data()))},
          {EncodableValue("prefixLength"),
           EncodableValue(static_cast<int32_t>(address->OnLinkPrefixLength))},
      });
      if (result.size() >= 32) return result;
    }
  }
  return result;
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterNetworkDiscovery(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), "nearlink/network_discovery",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "getInterfaces") {
      result->Success(EncodableValue(LocalIpv4Interfaces()));
    } else {
      result->NotImplemented();
    }
  });
  return channel;
}
