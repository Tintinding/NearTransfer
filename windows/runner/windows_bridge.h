#ifndef RUNNER_WINDOWS_BRIDGE_H_
#define RUNNER_WINDOWS_BRIDGE_H_

#include <windows.h>
#include <shellapi.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

class WindowsBridge {
 public:
  WindowsBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowsBridge();

  void Drop(HDROP drop);
  void SetPickerTitle(const std::wstring& title) { picker_title_ = title; }

 private:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              flutter::MethodResult<flutter::EncodableValue>& result);
  void Info(flutter::MethodResult<flutter::EncodableValue>& result);

  HWND window_;
  std::wstring picker_title_ = L"选择要发送的文件";
  HANDLE instance_lock_ = INVALID_HANDLE_VALUE;
  flutter::MethodChannel<flutter::EncodableValue> methods_;
  flutter::EventChannel<flutter::EncodableValue> drops_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> drop_sink_;
};

#endif  // RUNNER_WINDOWS_BRIDGE_H_
