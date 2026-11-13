<p align="center">
  <img src="macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="96" alt="近传图标">
</p>
<h1 align="center">近传 · NearTransfer</h1>
<p align="center">在同一局域网内，轻松传送文件。</p>

<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-176D56?style=for-the-badge" alt="简体中文"></a>
  <a href="docs/README.en.md"><img src="https://img.shields.io/badge/English-176D56?style=for-the-badge" alt="English"></a>
  <a href="docs/README.ja.md"><img src="https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-176D56?style=for-the-badge" alt="日本語"></a>
  <a href="docs/README.fr.md"><img src="https://img.shields.io/badge/Fran%C3%A7ais-176D56?style=for-the-badge" alt="Français"></a>
  <a href="docs/README.es.md"><img src="https://img.shields.io/badge/Espa%C3%B1ol-176D56?style=for-the-badge" alt="Español"></a>
</p>

近传是一款局域网文件传输工具。将设备连接到同一 IPv4 局域网，选择文件和附近设备，接收方确认后即可开始传输。使用时无需账号或互联网。

- **发现附近设备**：在设备列表中选择在线设备，成功传过文件的设备会显示标记。
- **发送多个文件**：支持多选文件，接收方确认后开始传输。接收时遇到同名文件会自动编号。
- **直接在局域网传输**：文件通过设备间的 HTTPS 连接发送，并在接收时校验大小与 SHA-256。
- **熟悉的界面**：Windows 支持拖入文件和系统托盘。Flutter 端提供中文、英语、日语、法语和西班牙语界面。

## 版本与下载

| 平台 | 当前状态 |
| --- | --- |
| Windows 11 x64 | 已提供可体验的单文件 EXE。 [下载 Windows 版](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Windows-x64.exe) |
| Android 10 及以上 | 已提供可体验的 APK。 [下载 Android 版](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Android.apk) |
| iOS / iPadOS | 尚无成品，仅提供实现原理和实验性源码，需要自行打包并验证。 [开发与验收](技术方案/iOS开发与验收.md) |
| macOS | 尚无成品，仅提供实现原理和实验性源码，需要自行打包并验证。 [开发与验收](技术方案/macOS开发与验收.md) |
| HarmonyOS NEXT | 尚无成品，仅提供实现原理和实验性源码，需要自行打包并验证。 [开发与验收](技术方案/HarmonyOS开发与验收.md) |

Windows 和 Android 体验包基于整合后的源码重新构建。此前 Windows 与 Android 曾双向传输照片和文档，新构建的 APK 尚未在真机验收，更多设备和网络场景仍待验证。 [发布页](https://github.com/Tintinding/NearTransfer/releases/tag/v1.0.0-preview)

## 开始使用

1. 在 Windows 电脑和 Android 手机安装或打开对应的体验版。
2. 让两台设备连接到同一 IPv4 局域网，并保持两端近传运行。
3. 在发送端选择文件和附近设备，点击「发送」。在接收端确认请求。
4. 传输完成后，在系统「下载」文件夹查看接收文件。

## 开发与构建

Windows、Android、macOS 和 iOS/iPadOS 共用 `lib/` 下的 Flutter 页面和 Dart 收发核心。各自的原生工程位于 `windows/`、`android/`、`macos/` 和 `ios/`。鸿蒙端位于 `harmonyos/`，使用 ArkTS 和 ArkUI。构建脚本位于 `tool/`，自动化测试位于 `test/`。 [公共技术方案](技术方案/公共技术方案.md)

Flutter 端点击右上角的「ZH ⇄ EN」可切换 English、简体中文、日本語、Français 和 Español。语言设置在本机保存，重启后自动恢复。系统文件选择器使用操作系统语言。

在本地构建时，Windows 单文件 EXE 和 Android APK 输出到 `release/`。

## HarmonyOS NEXT

鸿蒙源码使用 ArkTS 和 ArkUI，按同一 v1 局域网协议设计。用 DevEco Studio 打开 `harmonyos/`，选择产品 `default` 和模块 `entry`。HAP/APP 构建、签名及真机互传待验证。 [HarmonyOS 开发与验收](技术方案/HarmonyOS开发与验收.md)

## Windows 11 x64

下载后双击 `NearTransfer-Windows-x64.exe` 即可使用。这个文件可单独复制到任意文件夹，无需安装、手动解压或管理员权限。程序首次启动时会把内置运行文件准备到当前用户的 `%LOCALAPPDATA%\NearTransfer\runtime`，后续启动会复用该版本的运行文件。升级前请从托盘退出正在运行的旧版。

在 App 内可以用系统对话框多选，也可以从资源管理器拖入多个文件。接收完成后，可打开每个文件或在资源管理器中定位。保存路径随 Windows 的「下载」位置配置。

点窗口右上角的「×」会收起到任务栏右下角的系统托盘，设备仍可在局域网发现本机，进行中的传输继续运行。点击「近传」图标可恢复窗口。右键菜单可直接选择文件发送、查看接收请求、打开下载目录或退出。图标可能位于「^」隐藏图标区。

收在托盘时，新的传输请求会在近传自己的右下角小窗显示发送方和文件数量，Windows 勿扰模式开启时也能显示。点「接收」接受该请求并打开进度页，点「查看详情」可先检查文件清单。关掉小窗后仍可从托盘查看待确认请求。请求处理或超时后，小窗自动关闭。

使用 Flutter 3.50（Dart 3.14）、Visual Studio 的「使用 C++ 的桌面开发」工作负载和 Windows SDK。运行 `flutter doctor -v` 检查工具链。在仓库根目录用 PowerShell 7 构建并打包。

```powershell
./tool/build-windows.ps1
# Flutter 未加入 PATH 时可指定路径
# ./tool/build-windows.ps1 -Flutter 'C:/path/to/flutter/bin/flutter.bat'
```

脚本在临时英文路径执行 `flutter build windows --release`，再将完整 Release 目录嵌入 `release/NearTransfer-Windows-x64.exe`。内置文件包含 Flutter、Bonsoir、Visual C++ 运行库和应用资源。Flutter 在标准账户下无法创建插件符号链接时，脚本会在临时构建目录创建目录联接。 [Flutter Windows 分发](https://docs.flutter.dev/platform-integration/windows/building#distributing-windows-apps)

如果设备互相可见却连接超时，请确认两端仍在线，并检查 Windows 当前网络类型和防火墙入站权限。在受信任的专用网络中，可为 `%LOCALAPPDATA%\NearTransfer\runtime\<版本标识>\near_transfer.exe` 允许入站连接。升级时若运行文件路径变更，请按新版路径检查规则。 [Windows 防火墙](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/windows-firewall-with-advanced-security)

## macOS 构建

**尚无 macOS 成品，需自行构建并验证。** 源码设计为使用系统文件选择器多选，接收文件保存到当前账户的 `~/Downloads`，完成后可打开文件或在访达中定位。关闭最后一个窗口会退出近传。

在 Mac 上安装 Xcode 和 Flutter 3.50.0（Dart 3.14.0），将 Flutter 的 `bin` 加入 PATH。打开 Xcode 完成首次设置并同意许可。当前锁定的 Bonsoir 插件通过 Swift Package Manager 集成。 [Flutter macOS 开发环境](https://docs.flutter.dev/platform-integration/macos/setup) · [Flutter SDK 归档](https://docs.flutter.dev/install/archive)

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
flutter doctor -v
flutter pub get --enforce-lockfile
flutter gen-l10n
flutter run -d macos
```

退出调试后运行 `flutter build macos --release`。产物为 `build/macos/Build/Products/Release/NearTransfer.app`，可在访达中打开做本机验证。macOS 15 或更新版本若询问本地网络权限，请在弹窗中允许，或到「系统设置 → 隐私与安全性 → 本地网络」启用近传，再在 App 内点「重新检查」。

将含[工作流](.github/workflows/macos-release.yml)的分支推到 GitHub 后发起 PR，或向已打开的 PR 推送新提交。`macOS Release build` 会编译 Release，成功时在 Actions 页面提供 `NearTransfer-macOS-Release` 构建产物。工作流进入默认分支后，也可从 Actions 页面点 **Run workflow** 手动执行。构建使用本地临时签名（ad hoc），无需 Apple 账号、个人证书或密码。 [GitHub Actions 触发说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)

正式签名、公证和分发由 Mac 协作者使用自己的 Apple 开发环境完成。签名、打包步骤和真机清单见 [macOS 开发与验收](技术方案/macOS开发与验收.md)。

## iOS / iPadOS

**尚无 iOS/iPadOS 成品，需自行构建并验证。** 源码中的 Xcode Runner 目标面向 iPhone 和 iPad，设计使用 Bonjour 发现设备，支持预览和导出接收文件。模拟器、签名安装和真机验收步骤见 [iOS 开发与验收](技术方案/iOS开发与验收.md)。

## 自动化检查

```powershell
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
node --test test/readme_localization_test.cjs
```

鸿蒙主机测试使用 Node.js 24，包含与主项目 Dart 收发核心的双向 TLS 回环测试。运行 `flutter pub get` 后，在仓库根目录执行以下命令。Windows 使用 Flutter 自带的 `dart.exe`。

```powershell
$env:NEAR_TRANSFER_DART = Join-Path (Split-Path (Get-Command flutter).Source) 'cache/dart-sdk/bin/dart.exe'
node --test --test-concurrency=1 test/harmonyos/protocol.test.cjs test/harmonyos/interop.test.cjs
```

Windows Release 构建完成后，可先退出正在运行的近传，再在有任务栏的 Windows 桌面会话运行 `./test/windows_tray_test.ps1`，验证单个 EXE 从空目录启动，以及收起、恢复、托盘菜单、监听和退出。

## Android 构建

使用 Flutter 3.50（Dart 3.14）、Android SDK 36 和 Flutter 工具链支持的 JDK。APK 最低支持 Android 10（API 29），目标 API 36。调试构建可在英文路径运行 `flutter run`。

签名从构建进程的环境变量读取：`NEAR_TRANSFER_KEYSTORE`（密钥库绝对路径）、`NEAR_TRANSFER_STORE_PASSWORD`、`NEAR_TRANSFER_KEY_ALIAS`、`NEAR_TRANSFER_KEY_PASSWORD`。密钥和密码保存在仓库外。可从英文路径运行 `flutter build apk --release`。Windows 下若项目位于中文路径，运行下列命令；脚本将 Flutter 输入复制到临时英文路径，完成后清理并返回 APK 路径。

```powershell
./tool/build-android.ps1
# Flutter 未加入 PATH 时：./tool/build-android.ps1 -Flutter 'C:/path/to/flutter/bin/flutter.bat'
```

默认产物是 `release/NearTransfer-Android.apk`。可用 `adb install -r release/NearTransfer-Android.apk` 安装。覆盖安装需要使用相同签名。

## 与 Windows 测试端双向验收

让 App 和测试端接入同一支持组播的 IPv4 局域网，保持 Android、iPhone 或 iPad 上的近传在前台。Windows App 可在同一台电脑上使用实际局域网 IPv4 联调。把命令中的 IP 换成测试端电脑在该网络的 IPv4。若 Windows 询问防火墙权限，在受信任的专用网络中允许测试端的 Dart 入站连接。

```powershell
dart run tool/test_peer.dart 192.168.1.12 "$env:TEMP/neartransfer-pc"
```

- App 发送：在附近设备中选「Windows 测试端」，发送后在测试端输入 `accept` 或 `decline`。接收文件在测试目录的 `received` 下。
- 测试端发送：先输入 `list`，再按列表编号输入 `send 1 ["C:/Files/照片.jpg","C:/Files/视频.mp4"]`。在 App 内接受或拒绝。测试端支持 `cancel`、`retry`、`quit`。
- 核对两端发现、离线移除和重启后的「传过文件」。关闭外网并保留局域网，两向传输中文名、同名、空文件和超过 2 GiB 的视频。用 `Get-FileHash -Algorithm SHA256` 或等效工具对比收发文件。
- 批量上传时在第二个文件断网或取消：检查第一个文件仍在，待发布项已清理，恢复后只重试未确认的文件。还需在手机上检查多选、取消选档、存储不足、打开文件和锁屏恢复。

## v1 联调约定

DNS-SD 使用 `_neartransfer._tcp.local.`，TXT 键为 `v=1`、`id`（TLS 证书 DER 的 SHA-256）、`name` 和 `platform`；端口来自 SRV。应用只连接本地 IPv4 网段上发现的地址。首次传输以发现时的指纹约束 TLS，成功后按指纹保存记录。首次发现仍依赖当前局域网中的设备身份信息。

| 请求 | 正文或响应字段 |
| --- | --- |
| `POST /v1/offers` | UTF-8 JSON：`requestId`、`senderId`、`senderPort`、`files: [{id,name,size}]`。重复提交返回原会话。 |
| `POST /v1/verify-offer` | UTF-8 JSON：`requestId`、`receiverId`；返回 `verified`。 |
| `GET /v1/transfers/{id}` | 会话快照：`id`、`state`、`files: [{id,state,bytes,error?,name?}]`，仅接受时附 `token`。 |
| `PUT /v1/transfers/{id}/files/{fileId}` | 原始字节；`Authorization: Bearer <token>`、`Content-Length`、`X-Content-SHA256`。提交后返回单文件状态和实际文件名。 |
| `POST /v1/transfers/{id}/cancel` | 取消后返回会话快照，已提交项保留。 |

错误返回 HTTP 状态和 `{"error":"错误码"}`。会话 ID、请求 ID、上传令牌和文件 ID 使用 32 个小写十六进制字符，指纹和摘要使用 64 个小写十六进制字符，文件大小使用非负 64 位整数。每次最多 128 个文件，等待接收确认约 90 秒。状态枚举见 [共享模型](lib/transfer/model.dart)。
