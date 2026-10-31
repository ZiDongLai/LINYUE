#pragma once
#include <windows.h>
#include <bluetoothapis.h>
#include <cstdint>
#include <string>

namespace linyue_bluetooth {
// Existence in the classic API is deliberately NOT a Radio.State power value.
struct ClassicRadioProbe {
  bool present=false;
  bool queried=false;
  DWORD error=ERROR_SUCCESS, info_error=ERROR_SUCCESS;
  std::wstring name;
  std::string state() const {
    if(!queried) return "not-queried";
    if(present) return "present";
    if(error==ERROR_NO_MORE_ITEMS) return "no-radios";
    if(error==ERROR_ACCESS_DENIED) return "access-denied";
    return "query-error";
  }
};
inline ClassicRadioProbe ReadClassicRadio() {
  ClassicRadioProbe result;
  result.queried=true;
  BLUETOOTH_FIND_RADIO_PARAMS params{sizeof(params)};
  HANDLE radio=nullptr;
  SetLastError(ERROR_SUCCESS);
  const auto find=BluetoothFindFirstRadio(&params,&radio);
  if(!find) { result.error=GetLastError(); return result; }
  result.present=radio!=nullptr;
  if(!radio) result.error=ERROR_INVALID_HANDLE;
  else {
    BLUETOOTH_RADIO_INFO info{};info.dwSize=sizeof(info);
    result.info_error=BluetoothGetRadioInfo(radio,&info);
    if(result.info_error==ERROR_SUCCESS) result.name=info.szName;
    CloseHandle(radio);
  }
  BluetoothFindRadioClose(find);
  return result;
}
inline bool ParseBluetoothTarget(const std::string* id, uint64_t& address) {
  address=0;
  if(!id || id->size()!=12) return false;
  for(const char c:*id) {
    unsigned digit;
    if(c>='0' && c<='9') digit=c-'0';
    else if(c>='a' && c<='f') digit=c-'a'+10;
    else if(c>='A' && c<='F') digit=c-'A'+10;
    else return false;
    address=(address<<4)|digit;
  }
  return address!=0 && address!=0xffffffffffffULL && address!=0x020000000000ULL;
}
}
