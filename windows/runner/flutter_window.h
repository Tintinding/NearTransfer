#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <optional>
#include <string>

#include "win32_window.h"
#include "windows_bridge.h"
#include "windows_request_popup.h"

struct DesktopLabels {
  RequestPopupLabels popup;
  std::wstring open = L"打开近传";
  std::wstring pick = L"选择文件发送…";
  std::wstring receive = L"查看接收请求";
  std::wstring downloads = L"打开下载目录";
  std::wstring exit = L"退出近传";
  std::wstring picker_title = L"选择要发送的文件";
};

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();
  bool HandleDialogMessage(MSG& message) const;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct PendingOffer {
    std::string id;
    std::wstring text;
    int64_t expires_ms;
  };
  void RestoreFromTray(HWND window);
  void ShowPendingOffer();
  void RegisterDesktopChannel();
  void DesktopAction(const char* method, std::unique_ptr<flutter::EncodableValue> argument = nullptr);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<WindowsBridge> bridge_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_;
  std::unique_ptr<WindowsRequestPopup> request_popup_;
  DesktopLabels labels_;
  std::optional<PendingOffer> pending_offer_;
  UINT taskbar_created_ = 0;
  bool in_tray_ = false;
  bool exiting_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
