// E25-B1: Windows client only. No AF_INET, scan, pairing or LAN fallback.
#include <winsock2.h>
#include <ws2bth.h>
#include <windows.h>
#include <bluetoothapis.h>
#include <shellapi.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Rfcomm.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Radios.h>
#include "bluetooth_poc.h"
#include "bluetooth_async_wait.h"
#include "bluetooth_startup_probe.h"
#include "bluetooth_write_budget.h"
#include <flutter/standard_method_codec.h>
#include <atomic>
#include <chrono>
#include <deque>
#include <cstring>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

namespace linyue_bluetooth {
namespace {
using flutter::EncodableValue;
using flutter::EncodableMap;
using flutter::EncodableList;
constexpr size_t kLimit = 65536;
// c7941b72-4eb5-4a42-a164-25b100004672, same Android SDP UUID.
const GUID kService = {0xc7941b72,0x4eb5,0x4a42,{0xa1,0x64,0x25,0xb1,0x00,0x00,0x46,0x72}};
std::mutex mutex;
std::thread worker;
std::thread scan_worker;
std::atomic<bool> scan_in_progress{false};
std::vector<EncodableValue> scan_devices;
std::string scan_error;
std::atomic<bool> cancelled{true};
SOCKET active_socket = INVALID_SOCKET;
int32_t generation = 0;
std::string state = "idle", error;
std::string peer_id;
std::string service_state = "idle", service_error;
const auto diagnostic_clock=std::chrono::steady_clock::now();
std::deque<std::string> native_events;
uint64_t diagnostic_revision=0, last_poll_revision=0;
std::string query_stage="not-started", query_hresult, query_bluetooth_error;
std::string query_target_suffix, query_resolved_suffix, query_access="unknown";
std::string selected_service_uuid, selected_service_channel, last_service_outcome="not-started";
int query_count=-1;
int64_t query_elapsed_ms=0;
ClassicRadioProbe adapter_probe;
std::string last_native_call="not-started", preflight_stage="not-started", preflight_error;
bool target_present=false, target_valid=false;
int target_matches=-1, target_enumeration_error=0, target_input_length=-1;
std::string target_suffix;
std::string target_value_kind="not-started";
int native_attempt=0, winsock_error=0;
std::string radio_hresult, radio_query_status="not-started", radio_values;
int radio_count=-1;
std::string radio_state="unknown (refresh to query Windows Radio.State)";
std::chrono::steady_clock::time_point radio_observed_at{};
void TraceLocked(const std::string& message) {
  const auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-diagnostic_clock).count();
  const auto line=std::to_string(ms)+"ms gen="+std::to_string(generation)+" "+message.substr(0,280);
  native_events.push_back(line); if(native_events.size()>80) native_events.pop_front();
  ++diagnostic_revision;
  OutputDebugStringA(("LINYUE_BT "+line+"\n").c_str());
}
void Trace(const std::string& message) {
  std::lock_guard<std::mutex> guard(mutex); TraceLocked(message);
}
std::string HexError(int32_t code) {
  std::ostringstream out; out<<"0x"<<std::hex<<std::uppercase<<std::setfill('0')<<std::setw(8)<<static_cast<uint32_t>(code); return out.str();
}
std::string BluetoothErrorName(int code) {
  const char* names[]={"Success","RadioNotAvailable","ResourceInUse","DeviceNotConnected","OtherError","DisabledByPolicy","NotSupported","DisabledByUser","ConsentRequired","TransportNotSupported"};
  return code>=0 && code<10 ? names[code] : "Unknown";
}
EncodableMap DiagnosticsLocked() {
  flutter::EncodableList lines; for(const auto& line:native_events) lines.emplace_back(line);
  return {{EncodableValue("platform"),EncodableValue("windows")},
    {EncodableValue("serviceUuid"),EncodableValue("c7941b72-4eb5-4a42-a164-25b100004672")},
    {EncodableValue("nativeGeneration"),EncodableValue(generation)},
    {EncodableValue("phase"),EncodableValue(state)},
    {EncodableValue("lastNativeCall"),EncodableValue(last_native_call)},
    {EncodableValue("nativeAttempt"),EncodableValue(native_attempt)},
    {EncodableValue("preflightStage"),EncodableValue(preflight_stage)},
    {EncodableValue("preflightError"),EncodableValue(preflight_error)},
    {EncodableValue("targetPresent"),EncodableValue(target_present)},
    {EncodableValue("targetValid"),EncodableValue(target_valid)},
    {EncodableValue("targetInputLength"),EncodableValue(target_input_length)},
    {EncodableValue("targetValueKind"),EncodableValue(target_value_kind)},
    {EncodableValue("targetIdentityKind"),EncodableValue("classic-bd-addr-12hex; not DeviceInformation.Id")},
    {EncodableValue("targetSuffix"),EncodableValue(target_suffix)},
    {EncodableValue("targetPairedMatches"),EncodableValue(target_matches)},
    {EncodableValue("targetEnumerationError"),EncodableValue(target_enumeration_error)},
    {EncodableValue("adapterState"),EncodableValue(adapter_probe.state())},
    {EncodableValue("adapterWin32Error"),EncodableValue(static_cast<int64_t>(adapter_probe.error))},
    {EncodableValue("adapterInfoError"),EncodableValue(static_cast<int64_t>(adapter_probe.info_error))},
    {EncodableValue("winsockError"),EncodableValue(winsock_error)},
    {EncodableValue("radioQueryStatus"),EncodableValue(radio_query_status)},
    {EncodableValue("radioPowerState"),EncodableValue(radio_state)},
    {EncodableValue("radioSnapshotAgeMs"),EncodableValue(radio_observed_at==std::chrono::steady_clock::time_point{} ? int64_t(-1) : std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-radio_observed_at).count())},
    {EncodableValue("radioStateValues"),EncodableValue(radio_values)},
    {EncodableValue("radioCount"),EncodableValue(radio_count)},
    {EncodableValue("radioHresult"),EncodableValue(radio_hresult)},
    {EncodableValue("queryMethod"),EncodableValue("GetRfcommServicesForIdAsync(Uncached)")},
    {EncodableValue("queryStage"),EncodableValue(query_stage)},
    {EncodableValue("serviceOutcome"),EncodableValue(last_service_outcome)},
    {EncodableValue("resultCount"),EncodableValue(query_count)},
    {EncodableValue("hresult"),EncodableValue(query_hresult)},
    {EncodableValue("bluetoothError"),EncodableValue(query_bluetooth_error)},
    {EncodableValue("requestedSuffix"),EncodableValue(query_target_suffix)},
    {EncodableValue("resolvedSuffix"),EncodableValue(query_resolved_suffix)},
    {EncodableValue("access"),EncodableValue(query_access)},
    {EncodableValue("selectedUuid"),EncodableValue(selected_service_uuid)},
    {EncodableValue("selectedChannel"),EncodableValue(selected_service_channel)},
    {EncodableValue("elapsedMs"),EncodableValue(query_elapsed_ms)},
    {EncodableValue("events"),EncodableValue(lines)}};
}
std::vector<uint8_t> incoming;
std::deque<uint8_t> outgoing;
bool winsock_ready = false;
std::thread radio_worker;
std::atomic<bool> radio_busy{false};
std::atomic<bool> radio_cancelled{false};

void QueryRadio() {
  if (radio_busy.exchange(true)) return;
  if (radio_worker.joinable()) radio_worker.join();
  { std::lock_guard<std::mutex> guard(mutex);
    radio_state="unknown (querying Radio.State)"; radio_query_status="querying";
    radio_hresult.clear(); radio_count=-1; radio_values.clear();
  }
  radio_cancelled=false;
  radio_worker=std::thread([]() {
    std::string observed="unknown (no Bluetooth radio exposed)";
    std::string status="complete", hr, values;
    int count=0; bool apartment=false;
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      apartment=true;
      using namespace winrt::Windows::Devices::Radios;
      auto operation=Radio::GetRadiosAsync();
      if(!WaitForBluetoothOperation(operation,radio_cancelled,std::chrono::steady_clock::now()+std::chrono::seconds(15))) {
        status="timeout-or-cancelled"; observed="unknown (Radio.State query timeout/cancelled)";
      } else {
        const auto radios=operation.get();
        if(!radios) { status="null-result";observed="unknown (Radio.GetRadiosAsync null result)"; }
        else {
          bool on=false, off=false, disabled=false, unknown=false;
          for (const auto& radio:radios) {
            if(!radio || radio.Kind()!=RadioKind::Bluetooth) continue;
            const auto value=radio.State(); ++count;
            if(count<=16) values+=std::to_string(static_cast<int>(value))+",";
            on|=value==RadioState::On; off|=value==RadioState::Off;
            disabled|=value==RadioState::Disabled; unknown|=value==RadioState::Unknown;
          }
          observed=on ? "on" : unknown ? "unknown (RadioState.Unknown)" : off ? "off" : disabled ? "disabled" : "unknown (no Bluetooth radio exposed)";
          if(count==0) status="no-bluetooth-radios";
        }
      }
    } catch (const winrt::hresult_error& e) {
      hr=HexError(e.code().value); status="exception";
      observed="unknown (Radio.State HRESULT "+hr+")";
    } catch (const std::exception&) {
      status="exception"; observed="unknown (Radio.State native exception)";
    }
    if(apartment) winrt::uninit_apartment();
    { std::lock_guard<std::mutex> guard(mutex);
      radio_state=observed; radio_query_status=status; radio_hresult=hr; radio_values=values; radio_count=count;
      radio_observed_at=std::chrono::steady_clock::now();
      TraceLocked("Radio.GetRadiosAsync status="+status+" state="+observed+" count="+std::to_string(count)+" values="+values+" HRESULT="+hr);
    }
    radio_busy=false;
  });
}

std::string Address(BLUETOOTH_ADDRESS address) {
  std::ostringstream out;
  out << std::hex << std::setfill('0') << std::setw(12) << address.ullLong;
  return out.str();
}
std::string Utf8(const wchar_t* name) {
  const int count = WideCharToMultiByte(CP_UTF8,0,name,-1,nullptr,0,nullptr,nullptr);
  if (count <= 1) return "Bluetooth device";
  std::string value(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8,0,name,-1,value.data(),count,nullptr,nullptr);
  value.pop_back();
  return value;
}
bool Radio() {
  const auto result=ReadClassicRadio();
  std::lock_guard<std::mutex> guard(mutex); adapter_probe=result;
  return result.present;
}
std::string LocalName() {
  BLUETOOTH_FIND_RADIO_PARAMS params{sizeof(params)};
  HANDLE radio=nullptr;
  const auto find=BluetoothFindFirstRadio(&params,&radio);
  if (find==nullptr) return "";
  BLUETOOTH_RADIO_INFO info{}; info.dwSize=sizeof(info);
  const auto result=BluetoothGetRadioInfo(radio,&info);
  CloseHandle(radio); BluetoothFindRadioClose(find);
  return result==ERROR_SUCCESS ? Utf8(info.szName) : "";
}
flutter::EncodableList Devices(std::string* failure=nullptr, int* api_error=nullptr,
    bool issue_inquiry=false) {
  flutter::EncodableList list;
  BLUETOOTH_DEVICE_SEARCH_PARAMS params{};
  params.dwSize=sizeof(params); params.fReturnAuthenticated=TRUE;
  params.fReturnRemembered=TRUE;
  params.fReturnUnknown=issue_inquiry ? TRUE : FALSE;
  params.fIssueInquiry=issue_inquiry ? TRUE : FALSE;
  params.cTimeoutMultiplier=2;
  BLUETOOTH_DEVICE_INFO device{}; device.dwSize=sizeof(device);
  const auto find = BluetoothFindFirstDevice(&params,&device);
  if (find == nullptr) {
    const DWORD code=GetLastError();
    if(api_error) *api_error=static_cast<int>(code);
    if (failure && code!=ERROR_NO_MORE_ITEMS) *failure="Windows enumeration error "+std::to_string(code);
    return list;
  }
  do {
    list.emplace_back(EncodableMap{
      {EncodableValue("id"),EncodableValue(Address(device.Address))},
      {EncodableValue("name"),EncodableValue(Utf8(device.szName))},
      {EncodableValue("paired"),EncodableValue(device.fAuthenticated != FALSE)},
      {EncodableValue("kind"),EncodableValue(std::string(((device.ulClassofDevice>>8)&0x1f)==2 ? "phone" :
        ((device.ulClassofDevice>>8)&0x1f)==5 ? "peripheral" : "other"))}});
  } while (BluetoothFindNextDevice(find,&device));
  const auto next_error=GetLastError();
  if(next_error!=ERROR_NO_MORE_ITEMS) {
    if(api_error) *api_error=static_cast<int>(next_error);
    if(failure) *failure="Windows enumeration continuation error "+std::to_string(next_error);
  }
  BluetoothFindDeviceClose(find);
  return list;
}
bool CheckTarget(const EncodableMap* args, const char* call, std::string& canonical,
    BTH_ADDR& address, std::string& failure_code, std::string& detail) {
  const auto it=args ? args->find(EncodableValue("id")) : EncodableMap::const_iterator{};
  const auto* id=(!args || it==args->end()) ? nullptr : std::get_if<std::string>(&it->second);
  const std::string kind=!args ? "no-arguments" : it==args->end() ? "no-id-field" : id ? "string" : std::holds_alternative<std::monostate>(it->second) ? "null" : "non-string";
  uint64_t parsed=0;
  const bool valid=ParseBluetoothTarget(id,parsed);
  {
    std::lock_guard<std::mutex> guard(mutex);
    last_native_call=call; ++native_attempt; preflight_stage="validate-target";
    preflight_error.clear(); target_present=id!=nullptr; target_valid=valid;
    target_value_kind=kind;
    target_input_length=id ? static_cast<int>(id->size()) : -1;
    target_matches=-1; target_enumeration_error=0; target_suffix.clear();
    if(valid) { BLUETOOTH_ADDRESS value{};value.ullLong=parsed;canonical=Address(value);target_suffix=canonical.substr(6); }
    TraceLocked(std::string(call)+" input present="+(id ? "true" : "false")+" length="+std::to_string(target_input_length)+" valid="+(valid ? "true" : "false")+" suffix="+target_suffix);
  }
  const auto reject=[&](const std::string& code,const std::string& message) {
    failure_code=code; detail=message;
    std::lock_guard<std::mutex> guard(mutex);preflight_error=code+": "+message;TraceLocked(preflight_error);return false;
  };
  if(kind=="non-string") return reject("TARGET_INVALID","Target device ID has non-string platform type");
  if(!id || id->empty()) return reject("TARGET_MISSING","Target device ID missing before Windows native start; adapter/pairing not evaluated");
  if(!valid) return reject("TARGET_INVALID","Target must be a complete classic Bluetooth address (12 hex digits)");
  if(std::string(call)=="connect" && !winsock_ready) return reject("WINSOCK_STARTUP_FAILED","WinSock startup failed code="+std::to_string(winsock_error));
  {
    std::lock_guard<std::mutex> guard(mutex);preflight_stage="classic-adapter";
  }
  if(!Radio()) {
    ClassicRadioProbe observed;
    {std::lock_guard<std::mutex> guard(mutex);observed=adapter_probe;}
    if(observed.error==ERROR_NO_MORE_ITEMS) return reject("RADIO_NOT_FOUND","BluetoothFindFirstRadio returned no radios; Win32="+std::to_string(observed.error));
    if(observed.error==ERROR_ACCESS_DENIED) return reject("RADIO_ACCESS_DENIED","Windows adapter query access denied; Win32="+std::to_string(observed.error));
    return reject("RADIO_QUERY_FAILED","Windows adapter query failed; Win32="+std::to_string(observed.error));
  }
  std::string enumeration_error; int api_error=0, matches=0; bool peripheral=false;
  for(const auto& entry:Devices(&enumeration_error,&api_error)) {
    const auto& m=std::get<EncodableMap>(entry);
    if(_stricmp(std::get<std::string>(m.at(EncodableValue("id"))).c_str(),canonical.c_str())==0) {
      ++matches; peripheral=std::get<std::string>(m.at(EncodableValue("kind")))=="peripheral";
    }
  }
  {
    std::lock_guard<std::mutex> guard(mutex);preflight_stage="paired-target-match";
    target_matches=matches;target_enumeration_error=api_error;
    TraceLocked(std::string(call)+" paired matches="+std::to_string(matches)+" enumeration Win32="+std::to_string(api_error));
  }
  if(!enumeration_error.empty()) return reject("PAIRED_ENUMERATION_FAILED","Paired device enumeration failed: "+enumeration_error);
  if(matches==0) return reject("TARGET_NOT_PAIRED","Target not found in current OS-paired classic records; refresh pairing snapshot");
  if(peripheral) return reject("UNSUPPORTED_DEVICE","Unsupported peripheral, not a handset candidate");
  address=static_cast<BTH_ADDR>(parsed);
  {std::lock_guard<std::mutex> guard(mutex);preflight_stage="passed";TraceLocked(std::string(call)+" preconditions passed");}
  return true;
}
void Fail(const char* stage, int code) {
  std::lock_guard<std::mutex> guard(mutex);
  if (cancelled) return;
  state="error"; error=std::string(stage)+" (Windows error "+std::to_string(code)+")";
  TraceLocked(error);
}
void RunConnectedSocket(SOCKET sock, BTH_ADDR address) {
  {
    std::lock_guard<std::mutex> guard(mutex);
    if (cancelled) {
      if(active_socket==sock) active_socket=INVALID_SOCKET;
      closesocket(sock);
      return;
    }
    active_socket=sock;
    state="connected";
    BLUETOOTH_ADDRESS target{}; target.ullLong=address; peer_id=Address(target);
    TraceLocked("secure RFCOMM connected; application authentication still required");
  }
  while (!cancelled) {
    fd_set r,w; FD_ZERO(&r); FD_ZERO(&w); FD_SET(sock,&r);
    { std::lock_guard<std::mutex> guard(mutex); if (!outgoing.empty()) FD_SET(sock,&w); }
    timeval wait{0,50000};
    const int n=select(0,&r,&w,nullptr,&wait);
    if (cancelled) break;
    if (n==SOCKET_ERROR) { Fail("RFCOMM select",WSAGetLastError()); break; }
    if (FD_ISSET(sock,&r)) {
      char buffer[4096]; const int count=recv(sock,buffer,sizeof(buffer),0);
      if (count==0) { Fail("Peer disconnected",0); break; }
      if (count<0) { if (WSAGetLastError()==WSAEWOULDBLOCK) continue; Fail("RFCOMM read",WSAGetLastError()); break; }
      bool overflow=false;
      { std::lock_guard<std::mutex> guard(mutex);
        overflow=incoming.size()+static_cast<size_t>(count)>kLimit;
        if (!overflow) incoming.insert(incoming.end(),buffer,buffer+count);
      }
      if (overflow) { Fail("Receive queue limit",WSAENOBUFS); break; }
    }
    if (FD_ISSET(sock,&w)) {
      char buffer[4096]; int count=0;
      { std::lock_guard<std::mutex> guard(mutex);
        for (auto byte:outgoing) { buffer[count++]=static_cast<char>(byte); if (count==static_cast<int>(sizeof(buffer))) break; }
      }
      const int sent=send(sock,buffer,count,0);
      if (sent<0) { if (WSAGetLastError()==WSAEWOULDBLOCK) continue; Fail("RFCOMM write",WSAGetLastError()); break; }
      if (sent==0) { Fail("Zero-byte RFCOMM write",0); break; }
      { std::lock_guard<std::mutex> guard(mutex); for (int i=0;i<sent;++i) outgoing.pop_front(); }
    }
  }
  std::lock_guard<std::mutex> guard(mutex);
  if (active_socket==sock) { closesocket(sock); active_socket=INVALID_SOCKET; }
}

bool SetBluetoothService(SOCKET listener, WSAESETSERVICEOP operation) {
  SOCKADDR_BTH local{};
  int length=sizeof(local);
  if(getsockname(listener,reinterpret_cast<SOCKADDR*>(&local),&length)==SOCKET_ERROR) return false;
  CSADDR_INFO endpoint{};
  endpoint.LocalAddr.lpSockaddr=reinterpret_cast<LPSOCKADDR>(&local);
  endpoint.LocalAddr.iSockaddrLength=sizeof(local);
  endpoint.iSocketType=SOCK_STREAM;
  endpoint.iProtocol=BTHPROTO_RFCOMM;
  WSAQUERYSETW query{}; query.dwSize=sizeof(query);
  query.lpszServiceInstanceName=const_cast<LPWSTR>(L"LINYUE");
  query.lpServiceClassId=const_cast<GUID*>(&kService);
  query.dwNameSpace=NS_BTH;
  query.dwNumberOfCsAddrs=1;
  query.lpcsaBuffer=&endpoint;
  return WSASetServiceW(&query,operation,0)==0;
}

void RunServer() {
  SOCKET listener=socket(AF_BTH,SOCK_STREAM,BTHPROTO_RFCOMM);
  if(listener==INVALID_SOCKET) { Fail("RFCOMM server socket",WSAGetLastError()); return; }
  u_long listener_nonblocking=1;
  if(ioctlsocket(listener,FIONBIO,&listener_nonblocking)) {
    Fail("RFCOMM server nonblocking mode",WSAGetLastError()); closesocket(listener); return;
  }
  { std::lock_guard<std::mutex> guard(mutex); if(cancelled) { closesocket(listener); return; } active_socket=listener; }
  ULONG yes=TRUE;
  if(setsockopt(listener,SOL_RFCOMM,SO_BTH_AUTHENTICATE,reinterpret_cast<const char*>(&yes),sizeof(yes)) ||
     setsockopt(listener,SOL_RFCOMM,SO_BTH_ENCRYPT,reinterpret_cast<const char*>(&yes),sizeof(yes))) {
    Fail("Secure RFCOMM server options",WSAGetLastError());
    std::lock_guard<std::mutex> guard(mutex); if(active_socket==listener){closesocket(listener);active_socket=INVALID_SOCKET;} return;
  }
  SOCKADDR_BTH local{}; local.addressFamily=AF_BTH; local.serviceClassId=kService; local.port=BT_PORT_ANY;
  if(bind(listener,reinterpret_cast<SOCKADDR*>(&local),sizeof(local))==SOCKET_ERROR ||
     listen(listener,1)==SOCKET_ERROR) {
    Fail("RFCOMM server bind/listen",WSAGetLastError());
    std::lock_guard<std::mutex> guard(mutex); if(active_socket==listener){closesocket(listener);active_socket=INVALID_SOCKET;} return;
  }
  int local_size=sizeof(local);
  if(getsockname(listener,reinterpret_cast<SOCKADDR*>(&local),&local_size)==SOCKET_ERROR) {
    Fail("RFCOMM server channel",WSAGetLastError());
    std::lock_guard<std::mutex> guard(mutex); if(active_socket==listener){closesocket(listener);active_socket=INVALID_SOCKET;} return;
  }
  if(!SetBluetoothService(listener,RNRSERVICE_REGISTER)) {
    Fail("RFCOMM service registration",WSAGetLastError());
    std::lock_guard<std::mutex> guard(mutex); if(active_socket==listener){closesocket(listener);active_socket=INVALID_SOCKET;} return;
  }
  { std::lock_guard<std::mutex> guard(mutex); if(!cancelled){state="listening";TraceLocked("RFCOMM service advertised; waiting for paired computer");} }
  SOCKET accepted=INVALID_SOCKET; SOCKADDR_BTH remote{};
  while(!cancelled && accepted==INVALID_SOCKET) {
    fd_set reads; FD_ZERO(&reads); FD_SET(listener,&reads); timeval wait{0,100000};
    const int ready=select(0,&reads,nullptr,nullptr,&wait);
    if(ready==SOCKET_ERROR) { if(!cancelled) Fail("RFCOMM accept select",WSAGetLastError()); break; }
    if(ready>0) { int remote_size=sizeof(remote); accepted=accept(listener,reinterpret_cast<SOCKADDR*>(&remote),&remote_size); if(accepted==INVALID_SOCKET && !cancelled) { Fail("RFCOMM accept",WSAGetLastError()); break; } }
  }
  SetBluetoothService(listener,RNRSERVICE_DELETE);
  closesocket(listener);
  if(accepted==INVALID_SOCKET) {
    std::lock_guard<std::mutex> guard(mutex); if(active_socket==listener)active_socket=INVALID_SOCKET; return;
  }
  ULONG nonblocking=1;
  if(ioctlsocket(accepted,FIONBIO,&nonblocking) ||
     setsockopt(accepted,SOL_RFCOMM,SO_BTH_AUTHENTICATE,reinterpret_cast<const char*>(&yes),sizeof(yes)) ||
     setsockopt(accepted,SOL_RFCOMM,SO_BTH_ENCRYPT,reinterpret_cast<const char*>(&yes),sizeof(yes))) {
    Fail("Secure accepted RFCOMM socket",WSAGetLastError()); closesocket(accepted);
    std::lock_guard<std::mutex> guard(mutex); if(active_socket==listener)active_socket=INVALID_SOCKET; return;
  }
  { std::lock_guard<std::mutex> guard(mutex); if(active_socket==listener)active_socket=accepted; }
  RunConnectedSocket(accepted,remote.btAddr);
}

void Stop(const std::string& reason="unspecified") {
  cancelled=true;
  {
    std::lock_guard<std::mutex> guard(mutex);
    const bool idle=!worker.joinable() && active_socket==INVALID_SOCKET && state=="idle" && service_state=="idle" && incoming.empty() && outgoing.empty();
    TraceLocked("stop requested reason="+reason.substr(0,64)+"; previous="+state+" query="+service_state+(idle ? "; no-op" : "; invalidating generation"));
    if(idle) return;
    if (active_socket!=INVALID_SOCKET) {
      // Worker owns close; do not recycle this descriptor under in-flight I/O.
      shutdown(active_socket,SD_BOTH);
    }
  }
  if (worker.joinable()) worker.join();
  std::lock_guard<std::mutex> guard(mutex);
  if(service_state=="checking") { last_service_outcome="cancelled"; TraceLocked("service query cancelled before completion"); }
  ++generation; state="idle"; error.clear(); peer_id.clear(); incoming.clear(); outgoing.clear();
  service_state="idle"; service_error.clear();
}
// Uncached SDP query on a worker, not the Flutter platform thread. The deadline
// and Stop() cancel the WinRT operation; a result is capability, never identity.
template<typename T> bool AwaitService(const T& operation,
    std::chrono::steady_clock::time_point deadline) {
  return WaitForBluetoothOperation(operation,cancelled,deadline);
}
void ProbeService(BTH_ADDR address) {
  std::string outcome="error", detail, stage="apartment", hresult, bt_error;
  std::string resolved_suffix, access="unknown", selected_uuid, channel;
  int count=-1;
  const auto started=std::chrono::steady_clock::now();
  bool apartment=false;
  winrt::Windows::Devices::Bluetooth::BluetoothDevice device{nullptr};
  const auto mark=[&](const std::string& value) {
    stage=value;
    std::lock_guard<std::mutex> guard(mutex); query_stage=value; TraceLocked("query stage="+value);
  };
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded); apartment=true;
    using namespace winrt::Windows::Devices::Bluetooth;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
    mark("resolve-address");
    auto opening=BluetoothDevice::FromBluetoothAddressAsync(address);
    if (!AwaitService(opening,deadline)) { outcome="timeout"; }
    else {
      device=opening.get();
      if (!device) { detail="Service discovery: address did not resolve; access unknown"; }
      else {
        BLUETOOTH_ADDRESS resolved{}; resolved.ullLong=device.BluetoothAddress();
        resolved_suffix=Address(resolved).substr(6);
        if (resolved.ullLong!=address) throw winrt::hresult_invalid_argument(L"Resolved Bluetooth address mismatch");
        // Read access state only. RequestAccessAsync requires a UI-thread flow;
        // do not silently invoke consent from this worker or assume Allowed.
        try {
          const auto info=device.DeviceAccessInformation();
          if(info) {
            const int code=static_cast<int>(info.CurrentStatus());
            const char* names[]={"Unspecified","Allowed","DeniedByUser","DeniedBySystem"};
            access=std::string(code>=0 && code<4 ? names[code] : "Unknown")+" ("+std::to_string(code)+")";
          }
        }
        catch(const winrt::hresult_error& e) { access="unknown HRESULT="+HexError(e.code().value); }
        mark("target-service-query");
        auto querying=device.GetRfcommServicesForIdAsync(
          Rfcomm::RfcommServiceId::FromUuid(kService),BluetoothCacheMode::Uncached);
        if (!AwaitService(querying,deadline)) { outcome="timeout"; }
        else {
          auto found=querying.get();
          if(!found) { detail="Service discovery returned null result"; }
          else if (found.Error()!=BluetoothError::Success) {
            bt_error=BluetoothErrorName(static_cast<int>(found.Error()))+" ("+std::to_string(static_cast<int>(found.Error()))+")";
            detail="Service discovery BluetoothError="+bt_error;
          } else {
            bt_error="Success (0)";
            const auto services=found.Services();
            if(!services) { detail="Service discovery returned null service collection"; }
            else {
              count=static_cast<int>(services.Size()); outcome="missing";
              for(const auto& service:services) {
                if(service && service.ServiceId() && service.ServiceId().Uuid()==winrt::guid(kService)) {
                selected_uuid="c7941b72-4eb5-4a42-a164-25b100004672"; // Equality above verified the actual ServiceId.
                try { channel=winrt::to_string(service.ConnectionServiceName()); }
                catch(const winrt::hresult_error& e) { channel="unknown HRESULT="+HexError(e.code().value); }
                outcome="ready"; break;
                }
              }
            }
          }
        }
      }
    }
  } catch (const winrt::hresult_error& e) {
    hresult=HexError(e.code().value);
    detail="Service discovery stage="+stage+" HRESULT="+hresult+" ("+std::to_string(e.code().value)+"); "+winrt::to_string(e.message()).substr(0,180);
  } catch (const std::exception&) { detail="Service discovery failed"; }
  if(device) { try { device.Close(); } catch(...) {} device=nullptr; }
  if(apartment) winrt::uninit_apartment();
  std::lock_guard<std::mutex> guard(mutex);
  if (!cancelled) {
    service_state=outcome; service_error=detail; last_service_outcome=outcome;
    query_stage=stage; query_hresult=hresult; query_bluetooth_error=bt_error;
    query_resolved_suffix=resolved_suffix; query_access=access; query_count=count;
    selected_service_uuid=selected_uuid; selected_service_channel=channel;
    query_elapsed_ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-started).count();
    TraceLocked("query result="+outcome+" stage="+stage+" count="+std::to_string(count)+" BluetoothError="+bt_error+" HRESULT="+hresult);
  }
}
void Run(BTH_ADDR address) {
  Trace("RFCOMM socket create; secure authentication/encryption required");
  SOCKET sock=socket(AF_BTH,SOCK_STREAM,BTHPROTO_RFCOMM);
  if (sock==INVALID_SOCKET) { Fail("RFCOMM socket",WSAGetLastError()); return; }
  {
    std::lock_guard<std::mutex> guard(mutex);
    if (cancelled) { closesocket(sock); return; }
    active_socket=sock;
  }
  auto cleanup=[sock]() {
    std::lock_guard<std::mutex> guard(mutex);
    if (active_socket==sock) { closesocket(sock); active_socket=INVALID_SOCKET; }
  };
  BOOL yes=TRUE;
  if (setsockopt(sock,SOL_RFCOMM,SO_BTH_AUTHENTICATE,reinterpret_cast<const char*>(&yes),sizeof(yes)) ||
      setsockopt(sock,SOL_RFCOMM,SO_BTH_ENCRYPT,reinterpret_cast<const char*>(&yes),sizeof(yes))) {
    Fail("Secure RFCOMM options",WSAGetLastError()); cleanup(); return;
  }
  u_long nonblocking=1;
  if (ioctlsocket(sock,FIONBIO,&nonblocking)) { Fail("Nonblocking mode",WSAGetLastError()); cleanup(); return; }
  SOCKADDR_BTH remote{}; remote.addressFamily=AF_BTH; remote.btAddr=address;
  remote.serviceClassId=kService; remote.port=0; // Windows resolves this UUID using SDP.
  Trace("RFCOMM connect via fixed UUID; no LAN fallback");
  const int connected=connect(sock,reinterpret_cast<SOCKADDR*>(&remote),sizeof(remote));
  if (connected==SOCKET_ERROR && WSAGetLastError()!=WSAEWOULDBLOCK && WSAGetLastError()!=WSAEINPROGRESS) {
    Fail("RFCOMM connect/SDP UUID",WSAGetLastError()); cleanup(); return;
  }
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
  bool ready=connected==0;
  while (!cancelled && !ready && std::chrono::steady_clock::now()<deadline) {
    fd_set w,e; FD_ZERO(&w); FD_ZERO(&e); FD_SET(sock,&w); FD_SET(sock,&e);
    timeval wait{0,100000};
    const int n=select(0,nullptr,&w,&e,&wait);
    if (n==SOCKET_ERROR) { Fail("Connect select",WSAGetLastError()); cleanup(); return; }
    if (n>0) {
      int result=0; int size=sizeof(result);
      if (getsockopt(sock,SOL_SOCKET,SO_ERROR,reinterpret_cast<char*>(&result),&size) || result!=0) {
        Fail("RFCOMM connect/service",result==0 ? WSAGetLastError() : result); cleanup(); return;
      }
      ready=true;
    }
  }
  if (!ready || cancelled) { Fail("RFCOMM connection timeout/cancel",WSAETIMEDOUT); cleanup(); return; }
  RunConnectedSocket(sock,address);
}
} // namespace

std::unique_ptr<flutter::MethodChannel<EncodableValue>> Register(flutter::FlutterEngine* engine) {
  WSADATA data{}; winsock_error=WSAStartup(MAKEWORD(2,2),&data); winsock_ready=winsock_error==0;
  auto channel=std::make_unique<flutter::MethodChannel<EncodableValue>>(
    engine->messenger(),"nearlink/bluetooth_poc",&flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name()=="status") {
      Radio();
      ClassicRadioProbe observed;
      { std::lock_guard<std::mutex> guard(mutex); observed=adapter_probe; }
      QueryRadio();
      std::string enumeration_error;
      auto devices=Devices(&enumeration_error);
      EncodableMap diagnostic;
      { std::lock_guard<std::mutex> guard(mutex); diagnostic=DiagnosticsLocked(); }
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("permission"),EncodableValue(true)},
        {EncodableValue("radioAvailable"),observed.present ? EncodableValue(true) : observed.error==ERROR_NO_MORE_ITEMS ? EncodableValue(false) : EncodableValue()},
        {EncodableValue("adapterState"),EncodableValue(observed.state())},
        {EncodableValue("adapterError"),EncodableValue(static_cast<int64_t>(observed.error))},
        {EncodableValue("diagnostics"),EncodableValue(diagnostic)},
        {EncodableValue("localName"),EncodableValue(LocalName())},
        {EncodableValue("devicesError"),EncodableValue(enumeration_error)},
        {EncodableValue("devices"),EncodableValue(devices)}}));
    } else if (call.method_name()=="radioStatus") {
      std::lock_guard<std::mutex> guard(mutex);
      result->Success(EncodableValue(radio_state));
    } else if (call.method_name()=="openSettings") {
      const auto opened=ShellExecuteW(nullptr,L"open",L"ms-settings:bluetooth",nullptr,nullptr,SW_SHOWNORMAL);
      if (reinterpret_cast<INT_PTR>(opened)<=32) result->Error("SETTINGS","Unable to open Windows Bluetooth settings");
      else result->Success();
    } else if (call.method_name()=="diagnostics") {
      std::lock_guard<std::mutex> guard(mutex); result->Success(EncodableValue(DiagnosticsLocked()));
    } else if (call.method_name()=="scanDevices") {
      if (scan_in_progress.exchange(true)) { result->Success(); return; }
      if (scan_worker.joinable()) scan_worker.join();
      { std::lock_guard<std::mutex> guard(mutex); scan_devices.clear(); scan_error.clear(); TraceLocked("Bluetooth inquiry started; discovery results are not trusted identities"); }
      scan_worker=std::thread([]() {
        std::string failure; int api_error=0;
        auto found=Devices(&failure,&api_error,true);
        { std::lock_guard<std::mutex> guard(mutex);
          scan_devices.assign(found.begin(),found.end()); scan_error=failure;
          TraceLocked("Bluetooth inquiry completed; visible devices="+std::to_string(scan_devices.size())+" error="+std::to_string(api_error)); }
        scan_in_progress=false;
      });
      result->Success();
    } else if (call.method_name()=="scanStatus") {
      std::lock_guard<std::mutex> guard(mutex);
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("scanning"),EncodableValue(scan_in_progress.load())},
        {EncodableValue("devices"),EncodableValue(EncodableList(scan_devices.begin(),scan_devices.end()))},
        {EncodableValue("error"),EncodableValue(scan_error)},
        {EncodableValue("diagnostics"),EncodableValue(DiagnosticsLocked())}}));
    } else if (call.method_name()=="probeStatus") {
      std::lock_guard<std::mutex> guard(mutex);
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("generation"),EncodableValue(generation)},
        {EncodableValue("service"),EncodableValue(service_state)},
        {EncodableValue("error"),EncodableValue(service_error)},
        {EncodableValue("diagnostics"),EncodableValue(DiagnosticsLocked())}}));
    } else if (call.method_name()=="probeService") {
      const auto* args=std::get_if<EncodableMap>(call.arguments());
      std::string id,code,detail; BTH_ADDR address=0;
      if(!CheckTarget(args,"probeService",id,address,code,detail)) { result->Error(code,detail);return; }
      { std::lock_guard<std::mutex> guard(mutex);
        if (state=="connecting" || state=="connected" || service_state=="checking") {
          result->Error("BUSY","Connection or service query already active"); return;
        }
      }
      Stop("native-before-service-probe");
      int32_t gen;
      { std::lock_guard<std::mutex> guard(mutex);
        cancelled=false; service_state="checking"; gen=generation;
        query_target_suffix=id.substr(6); query_resolved_suffix.clear(); query_count=-1;
        query_hresult.clear(); query_bluetooth_error.clear(); query_access="unknown";
        selected_service_uuid.clear(); selected_service_channel.clear(); query_elapsed_ms=0;
        last_service_outcome="checking";
        TraceLocked("query requested; paired=true suffix="+query_target_suffix+" mode=Uncached uuid=c7941b72-4eb5-4a42-a164-25b100004672");
      }
      worker=std::thread(ProbeService,address);
      result->Success(EncodableValue(gen));
    } else if (call.method_name()=="stop") {
      std::string reason="platform-stop";
      if(const auto* args=std::get_if<EncodableMap>(call.arguments())) {
        const auto it=args->find(EncodableValue("reason"));
        if(it!=args->end()) if(const auto* value=std::get_if<std::string>(&it->second)) reason=value->substr(0,64);
      }
      Stop(reason); result->Success();
    } else if (call.method_name()=="poll") {
      std::lock_guard<std::mutex> guard(mutex);
      EncodableMap map{{EncodableValue("generation"),EncodableValue(generation)},
        {EncodableValue("state"),EncodableValue(state)}, {EncodableValue("error"),EncodableValue(error)},
        {EncodableValue("peerId"),EncodableValue(peer_id)},
        {EncodableValue("bytes"),EncodableValue(incoming)}};
      if(diagnostic_revision!=last_poll_revision) {
        map.emplace(EncodableValue("diagnostics"),EncodableValue(DiagnosticsLocked()));
        last_poll_revision=diagnostic_revision;
      }
      incoming.clear(); result->Success(EncodableValue(map));
    } else if (call.method_name()=="connect") {
      const auto* args=std::get_if<EncodableMap>(call.arguments());
      std::string id,code,detail; BTH_ADDR address=0;
      if(!CheckTarget(args,"connect",id,address,code,detail)) { result->Error(code,detail);return; }
      { std::lock_guard<std::mutex> guard(mutex);
        if (state=="connecting" || state=="connected") { result->Error("BUSY","Connection already active"); return; }
      }
      Stop("native-before-connect");
      int32_t gen;
      { std::lock_guard<std::mutex> guard(mutex); cancelled=false; state="connecting"; gen=generation; }
      worker=std::thread(Run,address);
      result->Success(EncodableValue(gen));
    } else if (call.method_name()=="start") {
      { std::lock_guard<std::mutex> guard(mutex);
        if(state=="connecting" || state=="connected" || state=="listening") { result->Error("BUSY","Bluetooth service already active"); return; }
      }
      Stop("native-before-listen");
      int32_t gen;
      { std::lock_guard<std::mutex> guard(mutex); cancelled=false; state="connecting"; gen=generation; }
      worker=std::thread(RunServer);
      result->Success(EncodableValue(gen));
    } else if (call.method_name()=="writeCapacity") {
      std::lock_guard<std::mutex> guard(mutex);
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("generation"),EncodableValue(generation)},
        {EncodableValue("queuedBytes"),EncodableValue(static_cast<int64_t>(outgoing.size()))}}));
    } else if (call.method_name()=="write") {
      const auto* args=std::get_if<EncodableMap>(call.arguments());
      if (!args) { result->Error("BAD_ARGUMENT","Missing write"); return; }
      const auto data=args->find(EncodableValue("bytes")), gen=args->find(EncodableValue("generation"));
      const auto* bytes=data==args->end() ? nullptr : std::get_if<std::vector<uint8_t>>(&data->second);
      const auto* requested=gen==args->end() ? nullptr : std::get_if<int32_t>(&gen->second);
      std::lock_guard<std::mutex> guard(mutex);
      if (!bytes || !requested || *requested!=generation || state!="connected" ||
          !CanQueueBluetoothBytes(outgoing.size(),bytes->size())) {
        result->Error("BLUETOOTH_POC","Stale handle, disconnected or send queue limit"); return;
      }
      outgoing.insert(outgoing.end(),bytes->begin(),bytes->end());
      result->Success(); // Local enqueue only, not delivery.
    } else { result->NotImplemented(); }
  });
  return channel;
}
void Shutdown() {
  radio_cancelled=true;
  Stop("native-shutdown"); if (radio_worker.joinable()) radio_worker.join();
  if (scan_worker.joinable()) scan_worker.join();
  if (winsock_ready) { WSACleanup(); winsock_ready=false; }
}
} // namespace linyue_bluetooth
