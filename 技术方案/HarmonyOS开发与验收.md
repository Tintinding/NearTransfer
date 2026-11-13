# 近传 · HarmonyOS NEXT 原生端

主项目的 `harmonyos/` 是原生 Stage 模型工程，界面使用 ArkUI，收发使用 ArkTS。打开两台设备上的近传，连接同一个 IPv4 局域网，从系统选择器选文件，再选中附近设备发送。对方接受后，两边可以查看进度和取消传输。首版面向手机和前台收发，界面为简体中文。

## 工程与兼容性

| 路径 | 内容 |
| --- | --- |
| `harmonyos/entry/src/main/ets/pages/`、`TransferApp.ets` | 手机发送、接收确认、进度与结果，以及前后台生命周期 |
| `harmonyos/entry/src/main/ets/core/` | v1 HTTPS 请求和响应、收发状态、流式校验、取消及回执核对 |
| `harmonyos/entry/src/main/ets/platform/` | Network Kit DNS-SD 与 TLS、系统文件选择与保存、运行时设备身份 |
| `test/harmonyos/` | 在 Windows 等开发机运行的协议测试，包括与主项目 Dart 端通过回环 TLS 双向传输 |

鸿蒙端沿用 Android 的选档和收发顺序，通过 ArkTS 实现系统文件操作和传输核心。各平台共用同一 v1 协议，包含 `_neartransfer._tcp`、TLS 叶证书 DER 的 SHA-256、反向验证、清单、令牌、状态和回执。 [v1 联调约定](../README.md#v1-联调约定)

每次安装在应用沙箱中生成并保存独立的 TLS 身份。连接时先核对同一条 TLS 连接上的证书指纹，再写入任何 HTTP 数据。首次发现依赖当前局域网广播的设备身份。接收端也会核对发送方的来源地址和发现记录，并反查本次请求。成功传过文件的设备指纹保存在本机，用于标记在线的旧设备。

上传前逐块计算 SHA-256，随后重新打开源文件逐块发送。接收端逐块写入暂存文件并计算摘要。每个文件通过长度和摘要验证后才提交，失败时清理暂存项。协议校验使用 ArkTS 可精确表示的整数范围，支持超过 2 GiB 的文件。超过 `Number.MAX_SAFE_INTEGER` 的文件大小或清单总量会被拒绝。应用进程运行期间可查询旧会话的提交状态，再只重试未完成的文件。若无法查到回执，界面要求先到接收端核对结果。退出进程后，系统选档授权和当前任务需重新取得。

## 工具链与导入

- 工程的编译、目标和最低兼容 SDK 均为 **HarmonyOS 6.0.0（API 20）**。API 20 提供关闭 TLS 监听端口的接口，供切到后台和换网时回收连接。使用支持 API 20 的 HarmonyOS 手机联调。 [Network Kit Socket 参考](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-socket/)
- 参考工具链为 **DevEco Studio 6.0.0 Release（6.0.0.878）**，随附 HarmonyOS 6.0.0 Release SDK、Hvigor 6.20.2、ohpm 5.3.2。CLI 可用同版官方 Command Line Tools。华为当前 Windows 安装要求为 16 GB 内存。 [SDK 配套版本](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/overview-600/) · [工具版本](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/deveco-studio-new-features-600/) · [安装要求](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-software-install/)
- 在 DevEco Studio 选择 **Open**，导入主项目里的 `harmonyos/`。选择 **Sync Now**，确认产品 `default` 与模块 `entry`。应用使用 SDK 内置 Kit。项目及模块的 ohpm 清单没有第三方库依赖。

## 构建、签名和安装

在 `harmonyos/` 下执行。先用仓库的空签名配置验证编译。CLI 使用官方工具包里的 `ohpm` 和 `hvigorw`。

```powershell
ohpm install --all
hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
hvigorw assembleApp --mode project -p product=default -p buildMode=release --no-daemon
```

在 `entry/build/default/outputs/default/` 查找 HAP。APP 的产物位置以 Hvigor 的构建输出为准。也可以在 IDE 的 **Build** 菜单分别构建 HAP 与 App Pack。保留 SDK、Hvigor 版本及完整构建错误；可使用 **Code > Inspect Code** 或随工具链提供的 `codelinter` 检查 ArkTS。 [命令行构建](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-command-line-building-app/) · [codelinter](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-command-line-codelinter/)

1. 在 API 20 或更高版本的测试机打开开发者模式与 USB 调试，连接电脑并批准调试。
2. 在 DevEco Studio 选择 **File > Project Structure > Project > Signing Configs**，使用获授权的华为开发者账号为本机配置调试签名。当前 bundle 名为 `app.neartransfer.neartransfer`。如果账号需要可注册的调试 bundle 名，仅在本地改 `AppScope/app.json5`，并在测试记录中写明。 [调试签名](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V5/ide-signing-V5/)
3. 选择真机，点 **Run** 让 IDE 安装已签名 HAP。手动安装时先执行 `hdc list targets`，再执行 `hdc install -r .\entry\build\default\outputs\default\entry-default-signed.hap`。请用实际产物名替换示例路径。发布时在有权限的 AppGallery Connect 项目配置发布证书和 profile，再构建已签名的 APP。 [安装和签名命令](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-command-line-building-app/) · [发布 APP](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/ide-publish-app/)

将签名材料和账号口令放在仓库外。自动签名可能写入本地 `build-profile.json5`，提交前用 `git diff --cached` 确认其中保留空的 `signingConfigs`。Issue 和 PR 也应去掉账号、设备标识及签名材料。

## 局域网权限与文件位置

- 工程声明 `ohos.permission.INTERNET` 用于 mDNS、监听和设备直连，`ohos.permission.GET_NETWORK_INFO` 用于判断 IPv4 局域网和网络切换。两项为系统授权。测试 WLAN 允许和拒绝时，到「设置 → 移动网络 → 流量管理 → 应用联网」检查近传的 WLAN 开关，菜单随设备系统而异。 [权限列表](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/permissions-for-all/) · [华为应用联网设置](https://consumer.huawei.com/cn/support/content/zh-cn16056653/)
- 选档使用 `DocumentViewPicker.select`，从系统授予的 URI 读取。接收时用 `DocumentViewPicker.save` 的 `DOWNLOAD` 模式请求系统授权。联调前可在「接收」页点「授权保存到下载」。首次接受请求时也会检查授权，授权完成后才进入接受状态。 [系统下载目录授权](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/save-user-file-V13/)
- 已提交文件位于「文件管理 → 下载 → `app.neartransfer.neartransfer`」应用目录。同名文件在扩展名前编号。暂存文件位于该目录的隐藏子目录，进程异常退出后的残留会在下次取得下载目录授权时清理。文件打开使用系统文件处理应用，分享使用系统分享面板。 [系统打开文件](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/file-processing-apps-startup/) · [系统分享](https://developer.huawei.com/consumer/en/doc/harmonyos-references/share-system-share)

## 本机检查

从仓库根目录运行。鸿蒙主机测试需要 Node.js 24。跨端测试通过 Dart CLI 启动本仓库的 v1 发送端和接收端。Windows 可用下列命令找到 Flutter 自带的 `dart.exe`。

```powershell
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
$env:NEAR_TRANSFER_DART = Join-Path (Split-Path (Get-Command flutter).Source) 'cache/dart-sdk/bin/dart.exe'
node --test --test-concurrency=1 test/harmonyos/protocol.test.cjs test/harmonyos/interop.test.cjs
```

合并后在 Windows 验证了主项目的 Flutter 静态分析、41 项 Flutter 测试和 11 项鸿蒙主机测试。鸿蒙主机测试包含使用主项目 Dart 核心的双向 TLS 回环传输。

| 检查 | 合并前鸿蒙分支的验证结果 |
| --- | --- |
| `flutter analyze` | 通过，无诊断 |
| `flutter test` | 21 项通过 |
| `node --test demo/tests/flow.test.cjs` | 7 项通过 |
| 鸿蒙主机协议测试 | 11 项通过。与现有 Dart 端双向 TLS 回环，校验约 9 MiB 文件、中文名、空文件和同名文件 |
| 主机静态检查 | TypeScript 5.8.3 严格类型检查通过，范围为协议及平台调用源码，参照 OpenHarmony 6.0 公共 API 声明。ArkUI 页面按官方文档审查 |

实际 HAP/APP 编译、ArkTS 编译器检查、签名安装、mDNS、局域网权限和手机上的文件操作等待协作者验证。

## 真机验收

- [ ] 鸿蒙与 Windows 双向发现、选择设备并传输。鸿蒙与 Android 按相同步骤双向测试。两台设备退出再打开，核对离线移除与「传过文件」。断外网时保留局域网，再试一次。
- [ ] 保持 Wi-Fi 连接，分别允许和禁止近传使用 WLAN。核对发现及传输是否被阻断、是否显示可操作提示，以及重新允许后是否恢复。若设备没有按应用控制 WLAN 的选项，记录系统版本和限制。
- [ ] 确认页显示发送方、文件名、数量和总大小。等待期间不出现接收文件。分别拒绝、等待超时及接受，核对双方结果。
- [ ] 双向传输中文名、空文件、同名文件和超过 2 GiB 的大文件。核对同名编号、大小及两端 SHA-256。传大文件时记录近传内存峰值。
- [ ] 传到批次第二个文件时，分别从两端取消和断开 Wi-Fi。确认已完成文件保留、未完成项清理。重连后核对回执，重试时仅发未完成文件，并再次确认。
- [ ] 拒绝与允许下载目录授权。验证「文件管理」中可找到已提交文件，以及打开和分享行为。模拟存储不足，检查提示、暂存清理与恢复后重试。异常关闭后重进并重新授权，检查残留清理。
- [ ] 锁屏、切到后台及切换 Wi-Fi 后回到前台，核对旧会话结束和附近设备重新出现。

Issue 或 PR 请附鸿蒙手机型号和系统版本、对端设备及系统版本、DevEco Studio 和 SDK/API 版本、两端提交号、传输方向、测试网络与权限开关、复现步骤、预期与实际结果。涉及完整性时，附测试文件大小和两端 SHA-256。构建失败时附命令和脱敏后的错误日志。

截至本次源码交付，Git 跟踪文件中未发现仓库级 `LICENSE`、`LICENCE` 或 `COPYING`。若需要公开分发或接收外部贡献，由仓库维护者先确认授权范围。
