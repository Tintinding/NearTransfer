#ifndef RUNNER_WINDOWS_REQUEST_POPUP_H_
#define RUNNER_WINDOWS_REQUEST_POPUP_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>

struct RequestPopupLabels {
  std::wstring app_name = L"近传";
  std::wstring title = L"收到文件请求";
  std::wstring view = L"查看详情";
  std::wstring accept = L"接收";
  std::wstring close = L"关闭提示";
};

class WindowsRequestPopup {
 public:
  using Action = std::function<void(const std::string&, bool)>;

  WindowsRequestPopup(HWND owner, Action action);
  ~WindowsRequestPopup();

  void Show(const std::string& id, const std::wstring& text, int64_t expires_ms,
            const RequestPopupLabels& labels = {});
  void Close();
  bool HandleMessage(MSG& message) const;

 private:
  static INT_PTR CALLBACK DialogProc(HWND window, UINT message,
                                     WPARAM wparam, LPARAM lparam);

  HWND owner_;
  HWND dialog_ = nullptr;
  HFONT title_font_ = nullptr;
  Action action_;
  std::string id_;
};

#endif  // RUNNER_WINDOWS_REQUEST_POPUP_H_
