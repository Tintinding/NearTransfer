# 近传 · Windows 开发方案

Windows App 使用 Flutter 界面、Dart 收发核心和必要的 Win32 桥接。首版以 **Windows 11 x64** 为构建和验收基线，交付可双击运行的单文件 EXE。共用接口、设备身份和协议见[公共技术方案](公共技术方案.md)。

## 平台实现

| 功能 | 实现 |
| --- | --- |
| 文件选择和拖拽 | 使用系统文件对话框，支持多选。主窗口接收资源管理器拖入的普通文件。选择与拖拽进入同一文件清单，只展示可读的文件及大小；发现目录、失效路径或不可读文件时给出对应提示。 |
| 下载目录 | 通过 `SHGetKnownFolderPath` 和 `FOLDERID_Downloads` 获取当前用户的 Downloads，支持用户改过位置的情况。用实际文件路径打开文件，并从资源管理器定位。 [Windows 已知目录](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid) |
| 文件写入和命名 | 在下载目录以应用生成的临时名创建文件并流式写入。校验成功后关闭文件，再用同目录、禁止覆盖的移动操作提交，例如不传 `MOVEFILE_REPLACE_EXISTING` 的 `MoveFileExW`。遇到同名占用就取下一个编号。处理保留名、非法字符、超长文件名和写入权限不足。失败或取消删除本次临时项，重启后清理可识别的本应用残留。 [MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw) |
| 局域网发现 | 接入共享发现接口。若插件无法可靠处理 Windows 注册、浏览或解析，使用 Win32 DNS-SD API。验证 Wi-Fi 和有线接口、网络切换及服务退出。 [DnsServiceBrowse](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsservicebrowse) |
| 防火墙和接收 | 在受信任的专用网络上用系统提示或应用入站规则允许接收监听。若可发现但连不上，提示检查 Windows 防火墙和网络类型。入站规则的程序路径为版本缓存中的 `near_transfer.exe`。 [Windows 防火墙](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/windows-firewall-with-advanced-security) |
| 桌面界面 | 沿用 Demo 的收发流程，宽窗口可同时展示文件清单和设备。调整窗口大小后仍能操作，支持键盘选择、删除待发送项和处理接收请求。「×」将窗口收起到系统托盘，保持发现和收发。托盘可选文件发送、查看接收请求和打开下载目录。选择「退出近传」时停止发布和监听，按公共规则结束当前传输。 |
| 收件提示 | 收起到托盘时，为身份已核验的待确认请求显示近传自己的右下角小窗。小窗沿用主界面的近传图标、绿白配色和圆角样式，显示时保留当前活动窗口的焦点，独立于 Windows 通知和勿扰设置。「查看详情」恢复主窗口，「接收」只接受与小窗对应的当前待确认请求。关闭小窗保留待确认请求，处理或超时后小窗自动关闭。 [Win32 非模态对话框](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createdialogparamw) |

## 开发顺序

1. **W1 · 构建和文件接口。** 安装并验证 Visual Studio 的「使用 C++ 的桌面开发」工作负载、Windows SDK 和 Flutter，运行 `flutter doctor -v`。完成系统选取、拖拽、Downloads 和打开位置。 [Flutter Windows 开发环境](https://docs.flutter.dev/platform-integration/windows/setup)
2. **W2 · 发现和连接。** 和局域网上的测试对端双向发布、发现和连接。验证 Windows 防火墙允许与阻断场景，验证从托盘退出 App 后对端设备列表更新。
3. **W3 · 完整收发。** 接入公共收发核心和页面。先用测试对端验收 Windows 的发送与接收，再加入 Android App 联调。
4. **W4 · 发布单文件 EXE。** 用 `flutter analyze`、`flutter test` 验证，运行 `flutter build windows --release`。将完整 Release 目录嵌入启动器，包含应用 EXE、Flutter DLL、插件 DLL、`data/` 和所需的 Visual C++ 运行库。启动器按内置文件内容划分版本缓存，核对运行文件并修复缺失或损坏的文件后启动应用。用干净 Windows 11 x64 环境测试离线启动和局域网互传。 [Flutter Windows 分发](https://docs.flutter.dev/platform-integration/windows/building#distributing-windows-apps)

## Windows 验收

- [ ] 标准用户可将单个 EXE 复制到空目录后双击启动，无需另装运行库。
- [ ] 文件选择和资源管理器拖入都支持单个与多个文件，清单大小正确。
- [ ] 保存到当前用户配置的 Downloads，中文名和同名编号正确。接收结果可打开并定位。
- [ ] 在专用网络上可双向发现和传输，防火墙阻断时提示可执行的下一步。
- [ ] 发送和接收大视频均可完成，验证大小、SHA-256 和进度。
- [ ] 批量中断保留已提交文件，取消及重启后无本应用遗留的未完成文件。重试只包括未提交项。
- [ ] 点击「×」后托盘可恢复窗口，收起期间设备仍在线。托盘退出后图标移除，监听和发现停止。

## 2026-11-12 开发机验收

环境为 Windows 11 x64、Flutter 3.50.0 / Dart 3.14.0、Visual Studio Community 2026。发行 ZIP 解压到含中文的路径后启动。App 和测试对端运行在同一台电脑，使用 WLAN 的 IPv4 地址。

| 执行命令或操作 | 结果 |
| --- | --- |
| `flutter doctor -v` | Windows 和 Visual Studio 工具链通过。 |
| `flutter analyze`、`flutter test`、`node --test demo/tests/flow.test.cjs` | 静态分析无问题，Flutter 16 项和 Demo 7 项通过。 |
| `./tool/build-windows.ps1`（内部运行 `flutter build windows --release`） | 中文路径直接构建时 AOT 工具无法读取 `app.dill`。脚本在临时英文路径构建成功，输出 `build/NearTransfer-Windows-x64/` 和同名 ZIP。解压后确认 EXE 与插件为 x64，ZIP 含 Flutter DLL、`data/` 和应用本地 VC++ 运行库。 |
| `dart run tool/test_peer.dart <本机 WLAN IPv4> "$peerRoot"`，在测试端输入 `list` | 测试端与 App 互相发布并解析 `_neartransfer._tcp.local.`。测试端的 TXT 记录按 UTF-8 编码后，App 正确显示「Windows 测试端」，因此保留 Bonsoir 7.3.1 的 Windows 实现。传输成功后两端显示「传过文件」。 |
| 测试端 `send 1 ["<中文文件>","<空文件>"]`，在 App 内接受 | 接受前 Downloads 中没有新文件；接受后生成编号文件，原同名文件保持原内容。`Get-FileHash -Algorithm SHA256` 核对两份接收文件一致。编号文件可由记事本打开，资源管理器可定位并选中。 |
| App 通过系统对话框选择中文文件、空文件和 2,147,483,665 字节的测试文件，在测试端输入 `accept` | 确认前测试目录无接收文件或临时项。确认后测试端回报 `Receive: completed (3/3)`，三项大小和 SHA-256 一致。 |
| 测试端再次 `send` 两文件，App 在第二个文件写入期间取消，测试端 `retry` | 已提交的第一项保留且 SHA-256 一致，第二项和 `.part` 均已清理。重试仅发送第二项，经再次接受后完成。2,147,483,665 字节的接收文件与源文件 SHA-256 一致。首次启动另验证了当前 Downloads 中可识别的旧 `.part` 会被清理。 |
| 在 App 内拒绝测试请求 | 测试端回报 `Send: declined (0/1)`，Downloads 中没有对应文件或临时项。 |
| 正常关闭 App 后在测试端输入 `list`，再从最终 ZIP 启动 | 关闭后测试端回报 `No nearby devices yet.`。最终 ZIP 解压版启动成功，恢复上次发送结果并标记在线测试端「传过文件」。 |

仍需用干净的 Windows 11 x64 标准账户验证 ZIP 离线启动，以及在 Windows 与 Android 两台设备上验证无外网互传、专用网络防火墙允许与阻断、网线和 Wi-Fi 切换、重定向后的实际 Downloads 和大视频。2026-11-12 已确认两台真机双向互传照片和文档成功；具体设备型号、文件完整性校验及网络条件未记录。拖拽事件进入共用清单和宽窄布局已通过自动化测试，资源管理器跨窗口实际拖放需手工验收。

托盘改动通过 `./test/windows_tray_test.ps1` 在 Windows Release 上验证。关闭窗口后进程和原 TCP 监听端口保持，托盘图标可恢复窗口，托盘菜单可打开，退出后进程结束且图标移除。

## 2026-11-13 托盘接收验证（系统通知版本）

在 Windows Release 窗口收起后，同机运行的 `dart run tool/test_peer.dart <本机 WLAN IPv4> <测试目录>` 通过 `list` 发现近传并发起请求。Windows 通知历史出现带「接收」按钮的通知。使用该按钮的实际参数调用 Windows 通知激活回调后，主窗口恢复，测试端报告 `Send: completed (1/1)`，落盘文件与源文件的 SHA-256 一致，通知随即移除。手机端发起托盘收件的场景仍需双机复验。

## 2026-11-13 应用收件小窗验证

在 Visual Studio Developer PowerShell 中，从仓库根目录运行以下原生测试。测试使用与 Release 相同的窗口代码和资源，覆盖隐藏主窗口时的圆角显示、前台焦点、关闭、查看详情、接收和超时。

```powershell
$testOut = Join-Path $env:TEMP ("neartransfer-popup-test-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $testOut | Out-Null
Push-Location windows/runner
try {
    rc.exe /nologo /fo "$testOut\popup.res" Runner.rc
    if ($LASTEXITCODE) { throw 'Failed to compile popup resources.' }
    cl.exe /nologo /std:c++17 /utf-8 /EHsc /W4 /WX /DNOMINMAX /DUNICODE /D_UNICODE /I . "/Fo$testOut\" "/Fe$testOut\popup_test.exe" ../../test/windows_request_popup_test.cpp windows_request_popup.cpp "$testOut\popup.res" /link user32.lib gdi32.lib
    if ($LASTEXITCODE) { throw 'Failed to compile popup test.' }
    & "$testOut\popup_test.exe"
    if ($LASTEXITCODE) { throw 'Popup test failed.' }
} finally {
    Pop-Location
}
```

本机原生测试通过。`flutter analyze` 无问题，`flutter test` 18 项通过，`node --test demo/tests/flow.test.cjs` 7 项通过。发布脚本完成 `flutter build windows --release`，输出 `build/NearTransfer-Windows-x64-Popup/` 和同名 ZIP，核对 ZIP 内的 EXE 与发布目录一致。

旧版仍在托盘运行，因此用独立状态目录的 Release 进行网络测试。执行 `dart run tool/test_peer.dart <测试端电脑的局域网 IPv4> <临时测试目录>`，用 `list` 找到托盘中的测试版，再用 `send 1 ["<测试文件路径>"]` 发起请求。关闭小窗后能从托盘重新看到请求，详情可恢复主窗口，接收后测试端报告 `Send: completed (1/1)`，Downloads 文件的 SHA-256 与源文件一致。再次请求时小窗保持当前前台焦点，测试端输入 `cancel` 后小窗关闭且没有生成重复文件。

`test/windows_tray_test.ps1` 的托盘启动、恢复、菜单和退出检查在发布版通过，监听保持在独立状态的测试版通过。手机在 Windows 开启勿扰时发起请求的组合场景待双机复验。

## 2026-11-13 单文件 EXE 验证

- `./tool/build-windows.ps1` 完成 Flutter Release 和 x64 启动器构建，生成 `build/NearTransfer-Windows-x64.exe`。启动器只动态链接 Windows 系统库，Flutter 和应用本地运行文件位于内置资源中。
- `./test/windows_tray_test.ps1` 在非提升的开发机桌面会话通过。测试只复制发布 EXE 到带中文和空格的空目录，改名为 `近传.exe` 后启动。确认出现主窗口，启动目录保持单文件，监听在收起时保持，托盘菜单和退出正常。另在独立的打包验证缓存中破坏一个文件并移除另一项资源，重启后两项恢复，完好的缓存 EXE 被复用。
- `dart run tool/test_peer.dart <测试端电脑的局域网 IPv4> <临时测试目录>` 用 `list` 发现收起到托盘的单文件发布版，用 `send 1 ["<测试文件>"]` 发起请求。通过小窗接收后报告 `Send: completed (1/1)`，Downloads 内文件的 SHA-256 与源文件一致。
- `flutter analyze` 无问题，`flutter test` 18 项通过，`node --test demo/tests/flow.test.cjs` 7 项通过。单文件版在干净 Windows 11 x64 上的离线启动及跨设备传输仍待验收。

## 2026-11-13 界面语言验证

- 右上角固定显示「ZH ⇄ EN」，点击后可在 English、简体中文、日本語、Français 和 Español 间切换。选择保存在当前用户的应用状态目录。主界面、传输状态、应用提示、托盘菜单、接收小窗和文件选择器标题使用所选语言。文件选择器的系统控件使用 Windows 语言。
- `flutter analyze` 无问题，`flutter test` 20 项通过，`node --test demo/tests/flow.test.cjs` 7 项通过。自动化测试覆盖窄窗口切换、重启恢复、无效设置回退和待确认请求在切换语言后仍可接受。原生小窗测试验证法文标题和按钮。
- 用单文件 Release 恢复法文设置并收起到托盘。通过 `dart run tool/test_peer.dart <测试端电脑的局域网 IPv4> <临时测试目录>` 的 `list` 和 `send` 发现并发起传输。小窗显示法文详情与接收按钮，点击接收后测试端报告 `Send: completed (1/1)`，接收文件与源文件的 SHA-256 一致。
- 最终产物 `build/NearTransfer-Windows-x64.exe` 通过 `./test/windows_tray_test.ps1`，验证从空目录独立启动、托盘保留监听、菜单、文件选择和正常退出。
