#include <winsock2.h>
#include <iphlpapi.h>
#include <ws2tcpip.h>

#include "windows_bridge.h"

#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;
using Microsoft::WRL::ComPtr;

std::optional<std::wstring> KnownPath(REFKNOWNFOLDERID folder, DWORD flags) {
  PWSTR raw = nullptr;
  const HRESULT status = SHGetKnownFolderPath(folder, flags, nullptr, &raw);
  std::optional<std::wstring> path;
  if (SUCCEEDED(status) && raw) {
    path = raw;
  }
  CoTaskMemFree(raw);
  return path;
}

std::wstring WidePath(const EncodableValue* value) {
  if (!value) {
    return {};
  }
  const auto* path = std::get_if<std::string>(value);
  if (!path || path->empty() || path->find('\0') != std::string::npos) {
    return {};
  }
  const int bytes = static_cast<int>(path->size());
  const int units =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(), bytes,
                          nullptr, 0);
  if (units == 0) {
    return {};
  }
  std::wstring wide(units, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(), bytes,
                      wide.data(), units);
  std::replace(wide.begin(), wide.end(), L'/', L'\\');
  return wide;
}

std::wstring ExtendedPath(const std::wstring& path) {
  if (path.rfind(L"\\\\?\\", 0) == 0) {
    return path;
  }
  if (path.rfind(L"\\\\", 0) == 0) {
    return L"\\\\?\\UNC\\" + path.substr(2);
  }
  return L"\\\\?\\" + path;
}

void PickFiles(HWND owner, const std::wstring& title, Result& result) {
  ComPtr<IFileOpenDialog> dialog;
  FILEOPENDIALOGOPTIONS options;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(dialog.GetAddressOf()))) ||
      FAILED(dialog->GetOptions(&options)) ||
      FAILED(dialog->SetOptions(options | FOS_ALLOWMULTISELECT |
                                FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST |
                                FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR))) {
    result.Error("picker_failed");
    return;
  }
  dialog->SetTitle(title.c_str());
  const HRESULT status = dialog->Show(owner);
  if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result.Success(EncodableValue(EncodableList{}));
    return;
  }
  ComPtr<IShellItemArray> items;
  DWORD count = 0;
  if (FAILED(status) || FAILED(dialog->GetResults(items.GetAddressOf())) ||
      FAILED(items->GetCount(&count))) {
    result.Error("picker_failed");
    return;
  }
  EncodableList paths;
  for (DWORD i = 0; i < count; ++i) {
    ComPtr<IShellItem> item;
    PWSTR path = nullptr;
    if (SUCCEEDED(items->GetItemAt(i, item.GetAddressOf())) &&
        SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
      paths.emplace_back(Utf8FromUtf16(path));
    }
    CoTaskMemFree(path);
  }
  result.Success(EncodableValue(std::move(paths)));
}

std::optional<std::string> LanNetworks() {
  ULONG size = 15 * 1024;
  std::vector<unsigned char> buffer(size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  constexpr ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                          GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_FRIENDLY_NAME;
  ULONG status = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &size);
  }
  if (status == ERROR_NO_DATA) {
    return std::string();
  }
  if (status != NO_ERROR) {
    return std::nullopt;
  }

  // Stable interface indexes make reconnects visible even if an address is
  // reused on another link. DNS-SD can discover on all eligible links.
  std::map<ULONG, std::vector<std::string>> networks;
  for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        (adapter->IfType != IF_TYPE_IEEE80211 &&
         adapter->IfType != IF_TYPE_ETHERNET_CSMACD) ||
        (adapter->Flags & IP_ADAPTER_NO_MULTICAST)) {
      continue;
    }
    std::vector<std::string> addresses;
    for (auto* address = adapter->FirstUnicastAddress; address;
         address = address->Next) {
      if (address->DadState != IpDadStatePreferred ||
          address->OnLinkPrefixLength == 0 || address->OnLinkPrefixLength > 32 ||
          !address->Address.lpSockaddr ||
          address->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      const auto* ip = reinterpret_cast<const sockaddr_in*>(
          address->Address.lpSockaddr);
      char text[INET_ADDRSTRLEN]{};
      if (InetNtopA(AF_INET, &ip->sin_addr, text, sizeof(text))) {
        addresses.emplace_back(std::string(text) + "/" +
                               std::to_string(address->OnLinkPrefixLength));
      }
    }
    if (!addresses.empty()) {
      std::sort(addresses.begin(), addresses.end());
      networks.emplace(adapter->IfIndex, std::move(addresses));
    }
  }
  if (networks.empty()) {
    return std::string();
  }
  std::string indexes;
  std::string subnets;
  for (const auto& [index, addresses] : networks) {
    if (!indexes.empty()) {
      indexes += ",";
    }
    indexes += std::to_string(index);
    for (const auto& address : addresses) {
      if (!subnets.empty()) {
        subnets += ",";
      }
      subnets += address;
    }
  }
  return indexes + ":" + subnets;
}

void Commit(const EncodableValue* arguments, Result& result) {
  const auto* paths =
      arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!paths) {
    result.Error("storage_failed");
    return;
  }
  const auto from = paths->find(EncodableValue("from"));
  const auto to = paths->find(EncodableValue("to"));
  const auto source = WidePath(from == paths->end() ? nullptr : &from->second);
  const auto target = WidePath(to == paths->end() ? nullptr : &to->second);
  if (source.empty() || target.empty()) {
    result.Error("storage_failed");
    return;
  }
  const auto destination = ExtendedPath(target);
  if (MoveFileExW(ExtendedPath(source).c_str(), destination.c_str(), 0)) {
    result.Success(EncodableValue(true));
    return;
  }
  const DWORD error = GetLastError();
  if (error == ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS ||
      (error == ERROR_ACCESS_DENIED &&
       GetFileAttributesW(destination.c_str()) != INVALID_FILE_ATTRIBUTES)) {
    result.Success(EncodableValue(false));
    return;
  }
  result.Error(error == ERROR_DISK_FULL || error == ERROR_HANDLE_DISK_FULL
                   ? "no_space"
                   : "storage_failed");
}

bool OpenPath(HWND owner, const std::wstring& path) {
  SHELLEXECUTEINFOW request{};
  request.cbSize = sizeof(request);
  request.fMask = SEE_MASK_FLAG_NO_UI;
  request.hwnd = owner;
  request.lpVerb = L"open";
  request.lpFile = path.c_str();
  request.nShow = SW_SHOWNORMAL;
  return ShellExecuteExW(&request) != FALSE;
}

bool Reveal(const std::wstring& path) {
  PIDLIST_ABSOLUTE item = nullptr;
  const HRESULT parsed =
      SHParseDisplayName(path.c_str(), nullptr, &item, 0, nullptr);
  const bool selected =
      SUCCEEDED(parsed) && SUCCEEDED(SHOpenFolderAndSelectItems(item, 0, nullptr, 0));
  CoTaskMemFree(item);
  return selected;
}

}  // namespace

WindowsBridge::WindowsBridge(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      methods_(messenger, "near_transfer/windows",
               &flutter::StandardMethodCodec::GetInstance()),
      drops_(messenger, "near_transfer/windows/drops",
             &flutter::StandardMethodCodec::GetInstance()) {
  methods_.SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, *result);
  });
  drops_.SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const auto*, auto&& events) {
            drop_sink_ = std::move(events);
            return nullptr;
          },
          [this](const auto*) {
            drop_sink_.reset();
            return nullptr;
          }));
  DragAcceptFiles(window_, TRUE);
}

WindowsBridge::~WindowsBridge() {
  DragAcceptFiles(window_, FALSE);
  drops_.SetStreamHandler(nullptr);
  methods_.SetMethodCallHandler(nullptr);
  if (instance_lock_ != INVALID_HANDLE_VALUE) {
    CloseHandle(instance_lock_);
  }
}

void WindowsBridge::Drop(HDROP drop) {
  EncodableList paths;
  const UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
  for (UINT i = 0; drop_sink_ && i < count; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    std::wstring path(length + 1, L'\0');
    if (DragQueryFileW(drop, i, path.data(), length + 1)) {
      paths.emplace_back(Utf8FromUtf16(path.c_str()));
    }
  }
  DragFinish(drop);
  if (drop_sink_ && !paths.empty()) {
    drop_sink_->Success(EncodableValue(std::move(paths)));
  }
}

void WindowsBridge::Info(Result& result) {
  const auto local = KnownPath(FOLDERID_LocalAppData, KF_FLAG_CREATE);
  if (!local) {
    result.Error("startup_failed");
    return;
  }
  const auto directory = *local + L"\\NearTransfer\\state";
  if (instance_lock_ == INVALID_HANDLE_VALUE) {
    std::error_code error;
    std::filesystem::create_directories(ExtendedPath(directory), error);
    if (error) {
      result.Error("startup_failed");
      return;
    }
    // One writer per user for identity, checkpoint and receive cleanup.
    const auto lock_path = ExtendedPath(directory + L"\\instance.lock");
    instance_lock_ = CreateFileW(lock_path.c_str(), GENERIC_WRITE, 0, nullptr,
                                 OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (instance_lock_ == INVALID_HANDLE_VALUE) {
      result.Error(GetLastError() == ERROR_SHARING_VIOLATION ? "already_running"
                                                            : "startup_failed");
      return;
    }
  }
  wchar_t computer[MAX_COMPUTERNAME_LENGTH + 1]{};
  DWORD length = MAX_COMPUTERNAME_LENGTH + 1;
  const auto name = GetComputerNameW(computer, &length)
                        ? Utf8FromUtf16(computer)
                        : std::string("Windows");
  result.Success(EncodableValue(EncodableMap{
      {EncodableValue("directory"), EncodableValue(Utf8FromUtf16(directory.c_str()))},
      {EncodableValue("name"), EncodableValue(name)},
  }));
}

void WindowsBridge::Handle(const flutter::MethodCall<EncodableValue>& call,
                           Result& result) {
  const auto& method = call.method_name();
  if (method == "info") {
    Info(result);
  } else if (method == "network") {
    const auto network = LanNetworks();
    if (network) {
      result.Success(EncodableValue(*network));
    } else {
      result.Error("network_permission");
    }
  } else if (method == "pick") {
    PickFiles(window_, picker_title_, result);
  } else if (method == "downloadsPath") {
    const auto path = KnownPath(FOLDERID_Downloads, KF_FLAG_DONT_VERIFY);
    if (path) {
      result.Success(EncodableValue(Utf8FromUtf16(path->c_str())));
    } else {
      result.Error("storage_failed");
    }
  } else if (method == "commit") {
    Commit(call.arguments(), result);
  } else if (method == "open" || method == "reveal") {
    const auto path = WidePath(call.arguments());
    if (!path.empty() && (method == "open" ? OpenPath(window_, path) : Reveal(path))) {
      result.Success();
    } else {
      result.Error("cannot_open");
    }
  } else {
    result.NotImplemented();
  }
}
