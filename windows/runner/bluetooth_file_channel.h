#ifndef LINYUE_BLUETOOTH_FILE_CHANNEL_H_
#define LINYUE_BLUETOOTH_FILE_CHANNEL_H_
#include "bluetooth_file_publish.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>
#include <memory>

namespace linyue_bt_file {
inline std::wstring Wide(const std::string& s) {
  Need(!s.empty()&&s.find('\0')==std::string::npos,"utf8",ERROR_INVALID_DATA);
  int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),static_cast<int>(s.size()),nullptr,0);
  Need(n>0,"utf8",ERROR_INVALID_DATA);std::wstring out(n,L'\0');
  MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),static_cast<int>(s.size()),out.data(),n);return out;
}
inline std::string Utf8(const std::wstring& s) {
  int n=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s.data(),static_cast<int>(s.size()),nullptr,0,nullptr,nullptr);
  Need(n>0,"utf8",ERROR_INVALID_DATA);std::string out(n,'\0');
  WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s.data(),static_cast<int>(s.size()),out.data(),n,nullptr,nullptr);return out;
}
inline std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> RegisterFiles(flutter::BinaryMessenger* messenger) {
  using V=flutter::EncodableValue;using M=flutter::EncodableMap;
  auto channel=std::make_unique<flutter::MethodChannel<V>>(messenger,"nearlink/bluetooth_file_commit",&flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const flutter::MethodCall<V>& call,std::unique_ptr<flutter::MethodResult<V>> result){
    if(call.method_name()!="commit"){result->NotImplemented();return;}
    try {
      auto args=call.arguments()?std::get_if<M>(call.arguments()):nullptr;Need(args!=nullptr,"arguments",ERROR_INVALID_DATA);
      auto string=[&](const char* key){auto i=args->find(V(key));Need(i!=args->end()&&std::holds_alternative<std::string>(i->second),"arguments",ERROR_INVALID_DATA);return std::get<std::string>(i->second);};
      auto i=args->find(V("size"));Need(i!=args->end(),"arguments",ERROR_INVALID_DATA);
      int64_t size=-1;if(auto n=std::get_if<int64_t>(&i->second))size=*n;else if(auto int32Value=std::get_if<int32_t>(&i->second))size=*int32Value;
      std::wstring nonce;
      if(args->find(V("commitNonce"))!=args->end())nonce=Wide(string("commitNonce"));
      auto verify=args->find(V("verifyOnly"));
      const bool verify_only=verify!=args->end()&&std::holds_alternative<bool>(verify->second)&&std::get<bool>(verify->second);
      auto saved=verify_only?RecoverReserved(Wide(string("inbox")),Wide(string("name")),size,string("sha256"),nonce):
        Publish(Wide(string("inbox")),Wide(string("path")),Wide(string("name")),size,string("sha256"),{},nonce);
      result->Success(V(M{{V("path"),V(Utf8(DartPath(saved.path)))},{V("size"),V(saved.size)},{V("sha256"),V(saved.sha)}}));
    }catch(const Failure& e){
      V details(M{{V("stage"),V(e.stage)},{V("win32Error"),V(static_cast<int64_t>(e.code))},{V("commitResult"),V("failed")}});
      std::string message=e.code==ERROR_DISK_FULL||e.code==ERROR_HANDLE_DISK_FULL?Utf8(L"电脑存储空间不足，文件未完成保存。"):
        e.code==ERROR_ACCESS_DENIED?Utf8(L"电脑接收目录不可写，文件未完成保存。"):Utf8(L"电脑文件提交失败，请保留诊断后重试。");
      result->Error("BT_FILE_COMMIT",message,details);
    }catch(...){result->Error("BT_FILE_COMMIT",Utf8(L"电脑文件提交失败，请保留诊断后重试。"));}
  });
  return channel;
}
} // namespace linyue_bt_file
#endif
