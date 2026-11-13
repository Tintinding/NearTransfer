#include <windows.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>

namespace {

namespace fs = std::filesystem;

struct PackageFile {
  WORD resource;
  const wchar_t* relative_path;
};

#include "package.inc"

void EnsureDirectory(const fs::path& path) {
  fs::create_directory(path);
  const auto attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    throw std::runtime_error("Invalid runtime directory");
  }
}

void EnsureDirectories(const fs::path& root, const fs::path& relative) {
  auto current = root;
  for (const auto& component : relative) {
    current /= component;
    EnsureDirectory(current);
  }
}

fs::path CacheRoot() {
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                nullptr, &local))) {
    throw std::runtime_error("LocalAppData unavailable");
  }
  std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owner(local, CoTaskMemFree);
  const fs::path local_path(local);
  const fs::path relative = L"NearTransfer/runtime";
  EnsureDirectories(local_path, relative);
  return local_path / relative;
}

// Closing the handle releases the lock, including after an interrupted launch.
class CacheLock {
 public:
  explicit CacheLock(const fs::path& path)
      : handle_(CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, nullptr)) {
    OVERLAPPED range{};
    BY_HANDLE_FILE_INFORMATION info{};
    if (handle_ == INVALID_HANDLE_VALUE ||
        !GetFileInformationByHandle(handle_, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        !LockFileEx(handle_, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &range)) {
      if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
      throw std::runtime_error("Cannot lock runtime cache");
    }
  }

  CacheLock(const CacheLock&) = delete;
  CacheLock& operator=(const CacheLock&) = delete;
  ~CacheLock() { CloseHandle(handle_); }

 private:
  HANDLE handle_;
};

bool Matches(const fs::path& path, const char* data, size_t size) {
  const auto attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
    return false;
  }
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file || file.tellg() != static_cast<std::streamoff>(size)) return false;
  file.seekg(0);
  std::array<char, 64 * 1024> buffer;
  while (size > 0) {
    const auto count = std::min(size, buffer.size());
    if (!file.read(buffer.data(), static_cast<std::streamsize>(count)) ||
        std::memcmp(buffer.data(), data, count) != 0) {
      return false;
    }
    data += count;
    size -= count;
  }
  return true;
}

void EnsureFile(HINSTANCE instance, const fs::path& runtime,
                const PackageFile& file) {
  const auto resource =
      FindResourceW(instance, MAKEINTRESOURCEW(file.resource), RT_RCDATA);
  if (!resource) throw std::runtime_error("Missing embedded resource");
  const DWORD size = SizeofResource(instance, resource);
  const auto data = static_cast<const char*>(
      LockResource(LoadResource(instance, resource)));
  if (!data && size != 0) throw std::runtime_error("Cannot read resource");

  const fs::path relative(file.relative_path);
  EnsureDirectories(runtime, relative.parent_path());
  const auto target = runtime / relative;
  if (Matches(target, data, size)) return;

  auto temporary = target;
  temporary += L".neartransfer-tmp";
  DeleteFileW(temporary.c_str());
  const HANDLE output = CreateFileW(
      temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (output == INVALID_HANDLE_VALUE) {
    throw std::runtime_error("Cannot write runtime file");
  }
  BY_HANDLE_FILE_INFORMATION info{};
  DWORD written = 0;
  const bool complete = GetFileInformationByHandle(output, &info) &&
                        !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
                        (size == 0 || WriteFile(output, data, size, &written, nullptr)) &&
                        written == size;
  const bool closed = CloseHandle(output) != FALSE;
  if (!complete || !closed ||
      !MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING)) {
    DeleteFileW(temporary.c_str());
    throw std::runtime_error("Cannot publish runtime file");
  }
}

void Launch(const fs::path& runtime, const wchar_t* arguments, int show) {
  const auto executable = runtime / L"near_transfer.exe";
  auto command = L"\"" + executable.wstring() + L"\"";
  if (*arguments) command += std::wstring(L" ") + arguments;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = static_cast<WORD>(show);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr,
                      FALSE, 0, nullptr, runtime.c_str(), &startup, &process)) {
    throw std::runtime_error("Cannot launch runtime");
  }
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, wchar_t* arguments, int show) {
  try {
    const auto cache = CacheRoot();
    const auto runtime = cache / kPackageId;
    const CacheLock lock(cache / L"prepare.lock");
    EnsureDirectory(runtime);
    for (const auto& file : kPackageFiles) EnsureFile(instance, runtime, file);
    Launch(runtime, arguments, show);
    return 0;
  } catch (const std::exception&) {
    MessageBoxW(nullptr,
                L"无法准备或启动近传。请检查本地磁盘空间和用户目录写入权限，再重新打开。",
                L"近传", MB_OK | MB_ICONERROR);
    return 1;
  }
}
