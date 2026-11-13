#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayOpen = 40001;
constexpr UINT kTrayExit = 40002;
constexpr UINT kTrayPick = 40003;
constexpr UINT kTrayReceive = 40004;
constexpr UINT kTrayDownloads = 40005;

NOTIFYICONDATAW TrayIcon(HWND window) {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window;
  icon.uID = kTrayIconId;
  return icon;
}

bool AddTrayIcon(HWND window, const std::wstring& name) {
  auto icon = TrayIcon(window);
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  wcsncpy_s(icon.szTip, name.c_str(), _TRUNCATE);
  if (!icon.hIcon || !Shell_NotifyIconW(NIM_ADD, &icon)) {
    return false;
  }
  icon.uVersion = NOTIFYICON_VERSION_4;
  if (Shell_NotifyIconW(NIM_SETVERSION, &icon)) {
    return true;
  }
  Shell_NotifyIconW(NIM_DELETE, &icon);
  return false;
}

void ShowTrayMenu(HWND window, const DesktopLabels& labels) {
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kTrayOpen, labels.open.c_str());
  SetMenuDefaultItem(menu, kTrayOpen, FALSE);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayPick, labels.pick.c_str());
  AppendMenuW(menu, MF_STRING, kTrayReceive, labels.receive.c_str());
  AppendMenuW(menu, MF_STRING, kTrayDownloads, labels.downloads.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExit, labels.exit.c_str());

  POINT position{};
  GetCursorPos(&position);
  NOTIFYICONIDENTIFIER identifier{};
  identifier.cbSize = sizeof(identifier);
  identifier.hWnd = window;
  identifier.uID = kTrayIconId;
  RECT bounds{};
  if (SUCCEEDED(Shell_NotifyIconGetRect(&identifier, &bounds))) {
    position = {bounds.left, bounds.top};
  }
  SetForegroundWindow(window);
  const UINT command =
      TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_RIGHTBUTTON | TPM_RETURNCMD |
                               TPM_NONOTIFY,
                     position.x, position.y, 0, window, nullptr);
  DestroyMenu(menu);
  // Let the shell dismiss the menu when focus moves to another window.
  PostMessageW(window, WM_NULL, 0, 0);
  if (command) {
    PostMessageW(window, WM_COMMAND, command, 0);
  } else {
    auto icon = TrayIcon(window);
    Shell_NotifyIconW(NIM_SETFOCUS, &icon);
  }
}

std::optional<DesktopLabels> ReadLabels(const flutter::EncodableValue* value) {
  const auto* map = value ? std::get_if<flutter::EncodableMap>(value) : nullptr;
  if (!map) return std::nullopt;
  DesktopLabels labels;
  const std::pair<const char*, std::wstring*> fields[] = {
      {"appName", &labels.popup.app_name}, {"open", &labels.open},
      {"pick", &labels.pick}, {"receive", &labels.receive},
      {"downloads", &labels.downloads}, {"exit", &labels.exit},
      {"pickerTitle", &labels.picker_title}, {"offerTitle", &labels.popup.title},
      {"view", &labels.popup.view}, {"accept", &labels.popup.accept},
      {"close", &labels.popup.close},
  };
  for (const auto& [key, field] : fields) {
    const auto entry = map->find(flutter::EncodableValue(key));
    if (entry == map->end()) return std::nullopt;
    const auto* text = std::get_if<std::string>(&entry->second);
    if (!text) return std::nullopt;
    *field = Utf16FromUtf8(*text);
    if (field->empty()) return std::nullopt;
  }
  return labels;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  bridge_ = std::make_unique<WindowsBridge>(
      GetHandle(), flutter_controller_->engine()->messenger());
  RegisterDesktopChannel();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  request_popup_.reset();
  if (desktop_) {
    desktop_->SetMethodCallHandler(nullptr);
    desktop_.reset();
  }
  bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterDesktopChannel() {
  using flutter::EncodableList;
  using flutter::EncodableValue;
  desktop_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), "near_transfer/windows/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  request_popup_ = std::make_unique<WindowsRequestPopup>(
      GetHandle(), [this](const std::string& id, bool accept) {
        if (!in_tray_ || exiting_ || !pending_offer_ || pending_offer_->id != id) {
          return;
        }
        RestoreFromTray(GetHandle());
        DesktopAction(accept ? "acceptOffer" : "viewOffer",
                      std::make_unique<EncodableValue>(id));
      });
  desktop_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "setLanguage") {
      auto labels = ReadLabels(call.arguments());
      if (!labels) {
        result->Error("invalid_language");
        return;
      }
      labels_ = std::move(*labels);
      SetWindowTextW(GetHandle(), labels_.popup.app_name.c_str());
      bridge_->SetPickerTitle(labels_.picker_title);
      if (in_tray_) {
        auto icon = TrayIcon(GetHandle());
        icon.uFlags = NIF_TIP | NIF_SHOWTIP;
        wcsncpy_s(icon.szTip, labels_.popup.app_name.c_str(), _TRUNCATE);
        Shell_NotifyIconW(NIM_MODIFY, &icon);
      }
      result->Success();
      return;
    }
    if (call.method_name() != "pendingOffer") {
      result->NotImplemented();
      return;
    }
    const auto* argument = call.arguments();
    if (!argument || argument->IsNull()) {
      pending_offer_.reset();
      request_popup_->Close();
      result->Success();
      return;
    }
    const auto* offer = std::get_if<EncodableList>(argument);
    if (offer && offer->size() == 3) {
      const auto* id = std::get_if<std::string>(&(*offer)[0]);
      const auto* text = std::get_if<std::string>(&(*offer)[1]);
      const auto* expires = std::get_if<int64_t>(&(*offer)[2]);
      if (id && id->size() == 32 &&
          id->find_first_not_of("0123456789abcdef") == std::string::npos &&
          text && expires) {
        pending_offer_ = PendingOffer{*id, Utf16FromUtf8(*text), *expires};
        ShowPendingOffer();
        result->Success();
        return;
      }
    }
    result->Error("invalid_offer");
  });
}

void FlutterWindow::ShowPendingOffer() {
  if (in_tray_ && !exiting_ && request_popup_ && pending_offer_) {
    const auto& offer = *pending_offer_;
    request_popup_->Show(offer.id, offer.text, offer.expires_ms, labels_.popup);
  }
}

bool FlutterWindow::HandleDialogMessage(MSG& message) const {
  return request_popup_ && request_popup_->HandleMessage(message);
}

void FlutterWindow::DesktopAction(
    const char* method, std::unique_ptr<flutter::EncodableValue> argument) {
  if (desktop_) desktop_->InvokeMethod(method, std::move(argument));
}

void FlutterWindow::RestoreFromTray(HWND window) {
  auto icon = TrayIcon(window);
  Shell_NotifyIconW(NIM_DELETE, &icon);
  in_tray_ = false;
  if (request_popup_) request_popup_->Close();
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Intercept the window close before Flutter runs its application exit hook.
  if (message == WM_CLOSE && !exiting_) {
    if (!in_tray_) {
      in_tray_ = AddTrayIcon(hwnd, labels_.popup.app_name);
      ShowWindow(hwnd, in_tray_ ? SW_HIDE : SW_MINIMIZE);
      ShowPendingOffer();
    }
    return 0;
  }
  if (message == kTrayMessage && HIWORD(lparam) == kTrayIconId) {
    if (in_tray_ && !exiting_) {
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
          RestoreFromTray(hwnd);
          break;
        case WM_CONTEXTMENU:
          ShowTrayMenu(hwnd, labels_);
          break;
      }
    }
    return 0;
  }
  if (message == WM_COMMAND && !lparam && HIWORD(wparam) == 0 &&
      in_tray_ && !exiting_) {
    switch (LOWORD(wparam)) {
      case kTrayOpen:
        RestoreFromTray(hwnd);
        return 0;
      case kTrayPick:
        RestoreFromTray(hwnd);
        DesktopAction("pick");
        return 0;
      case kTrayReceive:
        RestoreFromTray(hwnd);
        DesktopAction("receive");
        return 0;
      case kTrayDownloads:
        DesktopAction("downloads");
        return 0;
      case kTrayExit:
        // Let Flutter finish its existing transfer and discovery shutdown.
        exiting_ = true;
        if (request_popup_) request_popup_->Close();
        PostMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
    }
  }
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    if (in_tray_ && !exiting_ && !AddTrayIcon(hwnd, labels_.popup.app_name)) {
      RestoreFromTray(hwnd);
    }
    return 0;
  }
  if (message == WM_DESTROY && in_tray_) {
    auto icon = TrayIcon(hwnd);
    Shell_NotifyIconW(NIM_DELETE, &icon);
    in_tray_ = false;
  }
  if (message == WM_DROPFILES && bridge_) {
    bridge_->Drop(reinterpret_cast<HDROP>(wparam));
    return 0;
  }
  if (message == WM_GETMINMAXINFO) {
    const UINT dpi = GetDpiForWindow(hwnd);
    auto* bounds = reinterpret_cast<MINMAXINFO*>(lparam);
    bounds->ptMinTrackSize.x = MulDiv(400, dpi, 96);
    bounds->ptMinTrackSize.y = MulDiv(440, dpi, 96);
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
