#include "resource.h"
#include "windows_request_popup.h"

#include <chrono>
#include <iostream>
#include <stdexcept>
#include <utility>
#include <vector>

namespace {

int64_t NowMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

HWND FindPopup(HWND owner) {
  struct Search {
    HWND owner;
    HWND result;
  } search{owner, nullptr};
  EnumThreadWindows(GetCurrentThreadId(), [](HWND window, LPARAM data) -> BOOL {
    auto& search = *reinterpret_cast<Search*>(data);
    if (GetWindow(window, GW_OWNER) != search.owner ||
        !IsWindowVisible(window) || !GetDlgItem(window, IDC_REQUEST_ACCEPT)) {
      return TRUE;
    }
    search.result = window;
    return FALSE;
  }, reinterpret_cast<LPARAM>(&search));
  return search.result;
}

}  // namespace

int main() {
  try {
    const auto owner = CreateWindowExW(
        0, L"STATIC", L"NearTransfer test owner", WS_OVERLAPPEDWINDOW,
        80, 80, 500, 300, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    Check(owner != nullptr, "Could not create the test window");
    using Action = std::pair<std::string, bool>;
    std::vector<Action> actions;
    WindowsRequestPopup popup(owner, [&](const std::string& id, bool accept) {
      actions.emplace_back(id, accept);
    });

    const auto foreground = GetForegroundWindow();
    const RequestPopupLabels french{
        L"NearTransfer", L"Demande de transfert", L"Voir les détails",
        L"Accepter", L"Fermer l’alerte"};
    popup.Show("dismiss", L"Mon téléphone souhaite envoyer 1 fichier",
               NowMs() + 15000, french);
    const auto first = FindPopup(owner);
    Check(first && !IsWindowVisible(owner), "Popup should appear over a hidden owner");
    Check(GetForegroundWindow() == foreground, "Popup changed the foreground");
    Check((GetWindowLongPtrW(first, GWL_EXSTYLE) & WS_EX_NOACTIVATE) != 0,
          "Popup should not activate");
    Check((GetWindowLongPtrW(first, GWL_STYLE) & WS_CAPTION) == 0,
          "Popup should have no system caption");
    wchar_t label[64]{};
    GetDlgItemTextW(first, IDC_REQUEST_DETAILS, label, ARRAYSIZE(label));
    Check(label == french.view, "Popup should render the localized button");
    GetDlgItemTextW(first, IDC_REQUEST_TITLE, label, ARRAYSIZE(label));
    Check(label == french.title, "Popup should render the localized title");
    const auto region = CreateRectRgn(0, 0, 0, 0);
    const int shape = GetWindowRgn(first, region);
    DeleteObject(region);
    Check(shape == COMPLEXREGION, "Popup should have rounded corners");
    SendMessageW(GetDlgItem(first, IDCANCEL), BM_CLICK, 0, 0);
    Check(!FindPopup(owner) && actions.empty(), "Dismiss acted on the offer");

    popup.Show("details", L"Test phone", NowMs() + 15000);
    SendMessageW(GetDlgItem(FindPopup(owner), IDC_REQUEST_DETAILS), BM_CLICK, 0, 0);
    popup.Show("accept", L"Test phone", NowMs() + 15000);
    SendMessageW(GetDlgItem(FindPopup(owner), IDC_REQUEST_ACCEPT), BM_CLICK, 0, 0);
    Check(actions == std::vector<Action>{{"details", false}, {"accept", true}},
          "Popup buttons did not route to the active offer");

    popup.Show("expires", L"Test phone", NowMs() + 400);
    Check(FindPopup(owner) != nullptr, "Waiting offer did not show a popup");
    const auto limit = NowMs() + 4000;
    while (FindPopup(owner) && NowMs() < limit) {
      MSG message{};
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        if (!popup.HandleMessage(message)) DispatchMessageW(&message);
      }
      Sleep(10);
    }
    Check(!FindPopup(owner) && actions.size() == 2, "Expired popup stayed open");
    popup.Show("stale", L"Test phone", NowMs() - 1);
    Check(!FindPopup(owner), "Stale offer opened a popup");
    DestroyWindow(owner);
    std::cout << "Windows request popup passed.\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
