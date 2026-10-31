#ifndef LINYUE_BLUETOOTH_FILE_PUBLISH_H_
#define LINYUE_BLUETOOTH_FILE_PUBLISH_H_
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
#include <algorithm>
#include <cstdint>
#include <cwctype>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace linyue_bt_file {
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit Handle(HANDLE h) : value(h) {}
  ~Handle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};
struct Failure : std::runtime_error {
  std::string stage; DWORD code;
  Failure(std::string at, DWORD error) : std::runtime_error("Bluetooth received-file commit failed"), stage(std::move(at)), code(error) {}
};
inline void Need(bool ok, const char* stage, DWORD code = 0) {
  if (!ok) throw Failure(stage, code ? code : GetLastError());
}
inline bool Equal(const std::wstring& a, const std::wstring& b) {
  return CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(), static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}
inline std::wstring RealPath(HANDLE h) {
  DWORD count=GetFinalPathNameByHandleW(h,nullptr,0,FILE_NAME_NORMALIZED);
  Need(count && count<32768,"canonical-path");
  std::wstring p(count+1,L'\0');
  DWORD n=GetFinalPathNameByHandleW(h,p.data(),count+1,FILE_NAME_NORMALIZED);
  Need(n && n<=count,"canonical-path");p.resize(n);return p;
}
inline BY_HANDLE_FILE_INFORMATION Info(HANDLE h) {
  BY_HANDLE_FILE_INFORMATION i{};Need(GetFileInformationByHandle(h,&i)!=0,"file-info");return i;
}
inline bool SameFile(const BY_HANDLE_FILE_INFORMATION& a,const BY_HANDLE_FILE_INFORMATION& b) {
  return a.dwVolumeSerialNumber==b.dwVolumeSerialNumber && a.nFileIndexHigh==b.nFileIndexHigh && a.nFileIndexLow==b.nFileIndexLow;
}
// Dart's normal and extended path canonical strings differ. Keep native I/O
// on canonical handles, but return the same DOS/UNC spelling as path_provider.
inline std::wstring DartPath(const std::wstring& p) {
  if (p.starts_with(L"\\\\?\\UNC\\")) return L"\\\\" + p.substr(8);
  if (p.starts_with(L"\\\\?\\") && p.size() > 6 && p[5] == L':') return p.substr(4);
  return p;
}
inline std::wstring Parent(const std::wstring& p) {return p.substr(0,p.find_last_of(L'\\'));}
inline std::wstring Base(const std::wstring& p) {return p.substr(p.find_last_of(L'\\')+1);}
inline HANDLE Directory(const std::wstring& path) {
  HANDLE h=CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
  Need(h!=INVALID_HANDLE_VALUE,"open-directory");
  BY_HANDLE_FILE_INFORMATION i{};
  try { i=Info(h); } catch(...) { CloseHandle(h);throw; }
  if (!(i.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY) || (i.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)) {
    CloseHandle(h);throw Failure("reparse-directory-refused",ERROR_ACCESS_DENIED);
  }
  return h;
}
inline bool SafeName(const std::wstring& name) {
  if(name.empty()||name.size()>120||name.front()==L'.'||name.back()==L'.'||name.back()==L' ')return false;
  for(wchar_t c:name)if(c<32||std::wstring(L"\\/:*?\"<>|").find(c)!=std::wstring::npos)return false;
  auto stem=name.substr(0,name.find(L'.'));std::transform(stem.begin(),stem.end(),stem.begin(),::towupper);
  if(stem==L"CON"||stem==L"PRN"||stem==L"AUX"||stem==L"NUL"||
      (stem.size()==4&&(stem.substr(0,3)==L"COM"||stem.substr(0,3)==L"LPT")&&stem[3]>=L'1'&&stem[3]<=L'9'))return false;
  std::wstring lower=name;std::transform(lower.begin(),lower.end(),lower.begin(),::towlower);
  return !(lower.ends_with(L".part")||lower.ends_with(L".writing"));
}
inline std::string Hash(HANDLE file, int64_t expected) {
  LARGE_INTEGER size{};Need(GetFileSizeEx(file,&size)!=0 && size.QuadPart==expected,"length-check",ERROR_INVALID_DATA);
  LARGE_INTEGER zero{};Need(SetFilePointerEx(file,zero,nullptr,FILE_BEGIN)!=0,"rewind");
  BCRYPT_ALG_HANDLE alg=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
  Need(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0,"sha256-provider",ERROR_INVALID_DATA);
  DWORD bytes=0,length=0;
  if(BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&length),sizeof(length),&bytes,0)<0){BCryptCloseAlgorithmProvider(alg,0);throw Failure("sha256-provider",ERROR_INVALID_DATA);}
  std::vector<UCHAR> object(length),buffer(8192);UCHAR digest[32]{};
  if(BCryptCreateHash(alg,&hash,object.data(),length,nullptr,0,0)<0){BCryptCloseAlgorithmProvider(alg,0);throw Failure("sha256-create",ERROR_INVALID_DATA);}
  try {
    int64_t total=0;DWORD n=0;
    while(true){Need(ReadFile(file,buffer.data(),static_cast<DWORD>(buffer.size()),&n,nullptr)!=0,"read-file");if(!n)break;total+=n;
      Need(total<=expected && BCryptHashData(hash,buffer.data(),n,0)>=0,"hash-read",ERROR_INVALID_DATA);}
    Need(total==expected && BCryptFinishHash(hash,digest,32,0)>=0,"hash-finish",ERROR_INVALID_DATA);
  }catch(...){BCryptDestroyHash(hash);BCryptCloseAlgorithmProvider(alg,0);throw;}
  BCryptDestroyHash(hash);BCryptCloseAlgorithmProvider(alg,0);
  const char* hex="0123456789abcdef";std::string result;for(auto b:digest){result+=hex[b>>4];result+=hex[b&15];}return result;
}
struct Result { std::wstring path; int64_t size; std::string sha; };
// Hooks are only supplied by native disk tests; the app never injects failures.
inline Result Publish(const std::wstring& root, const std::wstring& temporary,
    const std::wstring& name,int64_t size,const std::string& sha,
    const std::function<bool(const char*)>& gate={},const std::wstring& reserved_nonce=L"",int64_t max_bytes=10485760) {
  static std::mutex mutex;std::lock_guard<std::mutex> hold(mutex);
  Need((max_bytes==1048576||max_bytes==10485760)&&SafeName(name)&&size>=0&&size<=max_bytes&&sha.size()==64&&
    std::all_of(sha.begin(),sha.end(),[](char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f');}),"metadata",ERROR_INVALID_DATA);
  Handle inbox(Directory(root));const auto actualRoot=RealPath(inbox.value);
  Handle source(CreateFileW(temporary.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
  Need(source.value!=INVALID_HANDLE_VALUE,"open-temporary");const auto identity=Info(source.value);
  Need(!(identity.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)),"temporary-kind",ERROR_ACCESS_DENIED);
  const auto actual=RealPath(source.value),rx=Parent(actual),work=Parent(rx);
  Need(Equal(Base(actual),L"payload.part")&&Base(rx).starts_with(L"rx_")&&
    Equal(work,actualRoot+L"\\.linyue_part_bt_e33"),"temporary-scope",ERROR_ACCESS_DENIED);
  Handle workHandle(Directory(work)),rxHandle(Directory(rx));
  Need(Info(inbox.value).dwVolumeSerialNumber==identity.dwVolumeSerialNumber,"same-volume",ERROR_NOT_SAME_DEVICE);
  Need(Hash(source.value,size)==sha,"temporary-sha256",ERROR_CRC);
  Need(FlushFileBuffers(source.value)!=0,"flush-temporary");
  auto step=[&](const char* at){if(gate)Need(gate(at),at,ERROR_WRITE_FAULT);};
  std::wstring nonce=reserved_nonce;
  if(nonce.empty()) {
    UCHAR random[16];Need(BCryptGenRandom(nullptr,random,16,BCRYPT_USE_SYSTEM_PREFERRED_RNG)>=0,"local-name",ERROR_INVALID_DATA);
    const wchar_t* hex=L"0123456789abcdef";
    for(auto b:random){nonce+=hex[b>>4];nonce+=hex[b&15];}
  } else Need(nonce.size()==32&&std::all_of(nonce.begin(),nonce.end(),[](wchar_t c){return (c>=L'0'&&c<=L'9')||(c>=L'a'&&c<=L'f');}),"reserved-name",ERROR_INVALID_DATA);
  const auto dot=name.find_last_of(L'.');auto stem=dot==std::wstring::npos?name:name.substr(0,dot);auto ext=dot==std::wstring::npos?L"":name.substr(dot);
  std::wstring target;bool moved=false;
  try {
    step("before-rename");
    for(int attempt=0;attempt<(reserved_nonce.empty()?100:1);++attempt){
      target=actualRoot+L"\\"+stem+L"_BT_"+nonce+(attempt?L" ("+std::to_wstring(attempt)+L")":L"")+ext;
      // Neither REPLACE_EXISTING nor COPY_ALLOWED: atomic same-volume no-clobber.
      if(MoveFileExW(actual.c_str(),target.c_str(),MOVEFILE_WRITE_THROUGH)){moved=true;break;}
      DWORD error=GetLastError();if(error!=ERROR_ALREADY_EXISTS&&error!=ERROR_FILE_EXISTS)throw Failure("rename",error);
    }
    Need(moved,"name-collision",ERROR_ALREADY_EXISTS);step("after-rename");
    Handle final(CreateFileW(target.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
    Need(final.value!=INVALID_HANDLE_VALUE,"open-final");Need(SameFile(identity,Info(final.value)),"final-identity",ERROR_INVALID_DATA);
    Need(Hash(final.value,size)==sha,"final-sha256",ERROR_CRC);step("flush-final");
    Need(FlushFileBuffers(source.value)!=0,"flush-final");
    return {target,size,sha};
  }catch(...){
    if(moved){
      // Only our still-open source inode was moved. Never delete unrelated files.
      if(!MoveFileExW(target.c_str(),actual.c_str(),MOVEFILE_WRITE_THROUGH))
        MoveFileExW(target.c_str(),(actualRoot+L"\\.linyue_part_bt_failed_"+nonce).c_str(),MOVEFILE_WRITE_THROUGH);
    }
    throw;
  }
}
inline Result RecoverReserved(const std::wstring& root,const std::wstring& name,int64_t size,
    const std::string& sha,const std::wstring& nonce,int64_t max_bytes=10485760) {
  Need((max_bytes==1048576||max_bytes==10485760)&&SafeName(name)&&size>=0&&size<=max_bytes&&sha.size()==64&&
    std::all_of(sha.begin(),sha.end(),[](char c){return(c>='0'&&c<='9')||(c>='a'&&c<='f');})&&
    nonce.size()==32&&std::all_of(nonce.begin(),nonce.end(),[](wchar_t c){return(c>=L'0'&&c<=L'9')||(c>=L'a'&&c<=L'f');}),"result-metadata",ERROR_INVALID_DATA);
  Handle inbox(Directory(root));auto actualRoot=RealPath(inbox.value);auto dot=name.find_last_of(L'.');
  auto stem=dot==std::wstring::npos?name:name.substr(0,dot),ext=dot==std::wstring::npos?L"":name.substr(dot);
  auto target=actualRoot+L"\\"+stem+L"_BT_"+nonce+ext;
  Handle file(CreateFileW(target.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
  Need(file.value!=INVALID_HANDLE_VALUE,"result-open");auto info=Info(file.value);
  Need(!(info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))&&Equal(Parent(RealPath(file.value)),actualRoot),"result-scope",ERROR_ACCESS_DENIED);
  Need(Hash(file.value,size)==sha,"result-sha256",ERROR_CRC);Need(FlushFileBuffers(file.value)!=0,"result-flush");
  return {target,size,sha};
}
} // namespace linyue_bt_file
#endif
