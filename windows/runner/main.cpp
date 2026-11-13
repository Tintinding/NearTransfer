#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <filesystem>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  wchar_t executable[32768];
  const DWORD path_length = GetModuleFileNameW(nullptr, executable, 32768);
  if (path_length == 0 || path_length == 32768) {
    return EXIT_FAILURE;
  }
  const auto data = std::filesystem::path(executable).parent_path() / L"data";
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(data.wstring());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Ignore activation of old system notifications after upgrading the app.
  if (command_line_arguments.size() == 1 &&
      _stricmp(command_line_arguments.front().c_str(), "-Embedding") == 0) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1000, 700);
  if (!window.Create(L"近传", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    if (window.HandleDialogMessage(msg)) continue;
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
