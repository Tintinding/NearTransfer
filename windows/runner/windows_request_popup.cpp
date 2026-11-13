#include "windows_request_popup.h"

#include <algorithm>
#include <chrono>
#include <utility>

#include "resource.h"

namespace {

constexpr UINT_PTR kExpiryTimer = 1;

// Match the palette of the Flutter receive screen in lib/main.dart.
constexpr COLORREF kGreen = RGB(25, 86, 64);
constexpr COLORREF kInk = RGB(32, 53, 44);
constexpr COLORREF kMuted = RGB(88, 107, 97);
constexpr COLORREF kLine = RGB(220, 229, 220);
constexpr COLORREF kLight = RGB(232, 242, 235);
constexpr COLORREF kWhite = RGB(255, 255, 255);

int Dip(HWND window, int value) {
  return MulDiv(value, GetDpiForWindow(window), 96);
}

void DrawRoundedRect(HDC dc, const RECT& bounds, int diameter,
                     COLORREF fill, COLORREF border) {
  const auto brush = GetStockObject(DC_BRUSH);
  const auto pen = GetStockObject(DC_PEN);
  const auto old_brush = SelectObject(dc, brush);
  const auto old_pen = SelectObject(dc, pen);
  const auto old_fill = SetDCBrushColor(dc, fill);
  const auto old_border = SetDCPenColor(dc, border);
  RoundRect(dc, bounds.left, bounds.top, bounds.right, bounds.bottom,
            diameter, diameter);
  SetDCBrushColor(dc, old_fill);
  SetDCPenColor(dc, old_border);
  SelectObject(dc, old_pen);
  SelectObject(dc, old_brush);
}

void DrawCard(HWND window, HDC dc) {
  RECT bounds{};
  GetClientRect(window, &bounds);
  DrawRoundedRect(dc, bounds, Dip(window, 24), kWhite, kLine);

  RECT badge{12, 10, 30, 28};
  MapDialogRect(window, &badge);
  DrawRoundedRect(dc, badge, Dip(window, 16), kLight, kLight);
  const int size = Dip(window, 24);
  const auto icon = reinterpret_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      size, size, LR_DEFAULTCOLOR));
  if (icon) {
    DrawIconEx(dc, (badge.left + badge.right - size) / 2,
               (badge.top + badge.bottom - size) / 2, icon, size, size, 0,
               nullptr, DI_NORMAL);
    DestroyIcon(icon);
  }
}

void DrawButton(const DRAWITEMSTRUCT& item) {
  const HDC dc = item.hDC;
  const int saved = SaveDC(dc);
  auto bounds = item.rcItem;
  const bool primary = item.CtlID == IDC_REQUEST_ACCEPT;
  const bool close = item.CtlID == IDCANCEL;
  const bool pressed = (item.itemState & ODS_SELECTED) != 0;
  FillRect(dc, &bounds, static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));
  const auto fill = primary ? (pressed ? kInk : kGreen)
                            : (pressed ? kLight : kWhite);
  const auto border = (primary || close) ? fill : kLine;
  DrawRoundedRect(dc, bounds, Dip(item.hwndItem, 16), fill, border);

  if (close) {
    const int x = (bounds.left + bounds.right) / 2;
    const int y = (bounds.top + bounds.bottom) / 2;
    const int radius = Dip(item.hwndItem, 4);
    SelectObject(dc, GetStockObject(DC_PEN));
    SetDCPenColor(dc, kMuted);
    MoveToEx(dc, x - radius, y - radius, nullptr);
    LineTo(dc, x + radius + 1, y + radius + 1);
    MoveToEx(dc, x - radius, y + radius, nullptr);
    LineTo(dc, x + radius + 1, y - radius - 1);
  } else {
    wchar_t label[32]{};
    GetWindowTextW(item.hwndItem, label, ARRAYSIZE(label));
    if (const auto font = SendMessageW(item.hwndItem, WM_GETFONT, 0, 0)) {
      SelectObject(dc, reinterpret_cast<HFONT>(font));
    }
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, primary ? kWhite : kGreen);
    DrawTextW(dc, label, -1, &bounds,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  }

  if (item.itemState & ODS_FOCUS) {
    InflateRect(&bounds, -4, -4);
    DrawFocusRect(dc, &bounds);
  }
  RestoreDC(dc, saved);
}

void ShowAtCorner(HWND window, HWND owner) {
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  RECT bounds{};
  if (GetMonitorInfoW(MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST),
                      &monitor) && GetWindowRect(window, &bounds)) {
    const auto& work = monitor.rcWork;
    const int margin = Dip(window, 16);
    const LONG x =
        std::max(work.left, work.right - (bounds.right - bounds.left) - margin);
    const LONG y =
        std::max(work.top, work.bottom - (bounds.bottom - bounds.top) - margin);
    SetWindowPos(window, HWND_TOPMOST, x, y, 0, 0,
                 SWP_NOACTIVATE | SWP_NOSIZE | SWP_SHOWWINDOW);
  } else {
    ShowWindow(window, SW_SHOWNOACTIVATE);
  }
}

void SetCardRegion(HWND window) {
  RECT bounds{};
  GetClientRect(window, &bounds);
  const int diameter = Dip(window, 24);
  const auto region =
      CreateRoundRectRgn(0, 0, bounds.right, bounds.bottom, diameter, diameter);
  if (region && !SetWindowRgn(window, region, TRUE)) DeleteObject(region);
}

}  // namespace

WindowsRequestPopup::WindowsRequestPopup(HWND owner, Action action)
    : owner_(owner), action_(std::move(action)) {}

WindowsRequestPopup::~WindowsRequestPopup() {
  Close();
}

void WindowsRequestPopup::Show(const std::string& id, const std::wstring& text,
                               int64_t expires_ms, const RequestPopupLabels& labels) {
  Close();
  const auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
  if (expires_ms <= now_ms) return;

  id_ = id;
  dialog_ = CreateDialogParamW(GetModuleHandleW(nullptr),
                               MAKEINTRESOURCEW(IDD_TRANSFER_REQUEST), owner_,
                               DialogProc, reinterpret_cast<LPARAM>(this));
  if (!dialog_) return;
  SetWindowTextW(dialog_, labels.app_name.c_str());
  SetDlgItemTextW(dialog_, IDC_REQUEST_TITLE, labels.title.c_str());
  SetDlgItemTextW(dialog_, IDC_REQUEST_TEXT, text.c_str());
  SetDlgItemTextW(dialog_, IDC_REQUEST_DETAILS, labels.view.c_str());
  SetDlgItemTextW(dialog_, IDC_REQUEST_ACCEPT, labels.accept.c_str());
  SetDlgItemTextW(dialog_, IDCANCEL, labels.close.c_str());
  const auto remaining =
      std::min<int64_t>(expires_ms - now_ms, USER_TIMER_MAXIMUM);
  SetTimer(dialog_, kExpiryTimer, static_cast<UINT>(remaining), nullptr);
  SetCardRegion(dialog_);
  ShowAtCorner(dialog_, owner_);
}

void WindowsRequestPopup::Close() {
  if (const HWND window = std::exchange(dialog_, nullptr)) {
    DestroyWindow(window);
  }
}

bool WindowsRequestPopup::HandleMessage(MSG& message) const {
  return dialog_ && IsDialogMessageW(dialog_, &message);
}

INT_PTR CALLBACK WindowsRequestPopup::DialogProc(HWND window, UINT message,
                                                  WPARAM wparam,
                                                  LPARAM lparam) {
  if (message == WM_INITDIALOG) {
    SetWindowLongPtrW(window, DWLP_USER, lparam);
    auto* self = reinterpret_cast<WindowsRequestPopup*>(lparam);
    const HWND title = GetDlgItem(window, IDC_REQUEST_TITLE);
    const auto font = reinterpret_cast<HFONT>(SendMessageW(title, WM_GETFONT, 0, 0));
    LOGFONTW style{};
    if (font && GetObjectW(font, sizeof(style), &style)) {
      style.lfHeight = MulDiv(style.lfHeight, 12, 10);
      style.lfWeight = FW_SEMIBOLD;
      self->title_font_ = CreateFontIndirectW(&style);
      if (self->title_font_) {
        SendMessageW(title, WM_SETFONT,
                     reinterpret_cast<WPARAM>(self->title_font_), FALSE);
      }
    }
    return FALSE;
  }

  auto* self = reinterpret_cast<WindowsRequestPopup*>(
      GetWindowLongPtrW(window, DWLP_USER));
  if (!self) return FALSE;
  if (message == WM_MOUSEACTIVATE) {
    SetWindowLongPtrW(window, DWLP_MSGRESULT, MA_NOACTIVATE);
    return TRUE;
  }
  if (message == WM_SIZE) SetCardRegion(window);
  if (message == WM_ERASEBKGND) return TRUE;
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    DrawCard(window, BeginPaint(window, &paint));
    EndPaint(window, &paint);
    return TRUE;
  }
  if (message == WM_PRINTCLIENT) {
    DrawCard(window, reinterpret_cast<HDC>(wparam));
    return TRUE;
  }
  if (message == WM_CTLCOLORSTATIC) {
    const auto dc = reinterpret_cast<HDC>(wparam);
    const int id = GetDlgCtrlID(reinterpret_cast<HWND>(lparam));
    SetTextColor(dc, id == IDC_REQUEST_TITLE ? kInk : kMuted);
    SetBkColor(dc, kWhite);
    return reinterpret_cast<INT_PTR>(GetStockObject(WHITE_BRUSH));
  }
  if (message == WM_DRAWITEM) {
    DrawButton(*reinterpret_cast<const DRAWITEMSTRUCT*>(lparam));
    return TRUE;
  }
  if (message == WM_CLOSE || (message == WM_TIMER && wparam == kExpiryTimer)) {
    self->Close();
    return TRUE;
  }
  if (message == WM_COMMAND) {
    const auto command = LOWORD(wparam);
    if (command == IDCANCEL) {
      self->Close();
      return TRUE;
    }
    if (command == IDC_REQUEST_DETAILS || command == IDC_REQUEST_ACCEPT) {
      const auto id = self->id_;
      self->Close();
      self->action_(id, command == IDC_REQUEST_ACCEPT);
      return TRUE;
    }
  }
  if (message == WM_NCDESTROY) {
    if (self->dialog_ == window) self->dialog_ = nullptr;
    if (const auto font = std::exchange(self->title_font_, nullptr)) {
      DeleteObject(font);
    }
  }
  return FALSE;
}
