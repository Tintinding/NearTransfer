# 近传 · macOS 开发与验收

**待 Mac 协作者验证。** 2026-11-13 在 Windows 完成代码、Dart 测试和工程静态检查。Xcode 编译、App 启动、权限弹窗、真机收发、签名和公证均待在 Mac 上验证。

## 实现与依赖

- `macos/Runner` 通过 AppKit 提供系统文件多选、打开文件和访达定位，从当前登录账户取得 Downloads 路径。私有状态保存到应用沙盒的 Application Support。文件选择的只读安全作用域书签随发送记录保存，供重启后重试。
- `lib/macos_bridge.dart` 接入公共的 Flutter 页面、Dart v1 收发核心和会话记录。发送和接收都按块读写。共享核心校验字节数和 SHA-256，校验成功后用 `renamex_np(..., RENAME_EXCL)` 提交 Downloads 中的临时文件。遇到同名占用时顺延编号。取消和失败回滚临时项，重试沿用未提交项规则。
- `pubspec.lock` 锁定 Bonsoir 7.1.6 和 bonsoir_darwin 7.1.2。核对包源码和 Flutter 注册代码后保留现有实现。Darwin 端用 `DNSServiceRegister` 发布，`NWBrowser` 浏览，`DNSServiceResolve` 和 `DNSServiceGetAddrInfo` 解析 `_neartransfer._tcp.local.` 的端口和地址。共享发现层仍按本地 IPv4 网段筛选。实际注册、解析和移除待真机验证。 [Bonsoir Darwin](https://pub.dev/packages/bonsoir_darwin/versions/7.1.2)
- Debug、Profile 和 Release 均启用 App Sandbox、入站和出站网络、Downloads 读写及用户选档只读权限。`Info.plist` 声明 Bonjour 类型和本地网络用途。首次发现前和列表为空时提供授权提示，发现失败后可重新检查。App 隐藏时停止发现和监听，进行中的传输按中断处理。恢复窗口后重新发现，可重试未完成项。关闭最后一个窗口退出。 [Apple 局域网权限说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## Windows 本地验证

| 命令或检查 | 结果 |
| --- | --- |
| `flutter pub get --enforce-lockfile`、`flutter gen-l10n` | 依赖按锁定版本恢复，五种语言生成成功。 |
| `flutter analyze` | 通过，未报告问题。 |
| `flutter test` | 28 项通过，含共享协议测试、现有 Windows/Android 界面测试和 7 项新增 macOS Dart 测试。macOS 测试通过模拟平台通道验证选档和书签、分块读写、同名提交、取消和清理、窗口布局及权限提示。 |
| `node --test demo/tests/flow.test.cjs` | 7 项通过。 |
| `actionlint .github/workflows/macos-release.yml` | 通过。 |
| Python 静态检查 | 通过。解析 Xcode 工程、scheme、XIB、Info.plist 和 entitlements，核对 Runner 源文件、产物引用和图标尺寸，并用 tree-sitter 检查 Swift 语法。 |

## 待 Mac 协作者验证

按 [README 的 macOS 步骤](../README.md#macos-构建)安装依赖、运行调试版和构建 Release。将构建日志中的提交、macOS 版本、芯片架构、Xcode 和 Flutter 版本写入 PR。用同一支持组播的 IPv4 局域网和真实 Windows、Android App 验收，保持近传窗口可见、Android App 在前台。每个方向先验证双方发现，再分别接受和拒绝一次。接受前及拒绝后，接收端均应无该批次文件和临时项。

| 方向 | 双向发现、接受并完成传输、拒绝 |
| --- | --- |
| macOS → Windows | ☐ |
| Windows → macOS | ☐ |
| macOS → Android | ☐ |
| Android → macOS | ☐ |

- [ ] **构建与启动**。PR 的 `macOS Release build` 通过并生成 ZIP。记录 `lipo -archs` 输出。在 Mac 用 `flutter run -d macos` 启动 Debug，再在访达双击 Release `NearTransfer.app`。检查宽窄窗口、切换语言、最小化或隐藏后恢复、红色关闭按钮和 ⌘Q。退出后对端设备列表应移除本机。
- [ ] **文件与 Downloads**。多选中文名、空文件和普通文件，取消选档后清单不增加。Mac 接收前在 `~/Downloads` 放入一个同名文件，确认原文件内容保留，新文件显示为「名称 (1).扩展名」。在结果页分别打开文件、在访达中定位文件和打开下载目录。核对实际路径属于测试账户。
- [ ] **大文件与校验**。保留局域网、断开外网，测试 Mac 发送和接收超过 2 GiB 的文件。比对双方的字节数和 SHA-256，观察进度。Mac 用 `stat -f '%z' "<文件>"` 和 `shasum -a 256 "<文件>"`，Windows 用 `Get-FileHash -Algorithm SHA256 -LiteralPath '<文件>'`。Android 可用 `adb pull` 拉取接收文件后在电脑上计算摘要。
- [ ] **取消、断线和重试**。先发送小文件，待第二个大文件上传时分别测试发送方取消、接收方取消和断网。第一项应保留，第二项的未完成文件和 `.part` 应清理。恢复网络后重试，仅重新请求剩余项，接收方再次确认后完成。对 Mac 发送端另测退出再打开后重试 Downloads 之外选过的文件，并确认设备仍有「传过文件」标记。
- [ ] **本地网络允许和拒绝**。在 macOS 15 或更新版本用访达启动拟分发的签名 App。用未启动过该 App 的测试账户核对首次提示。拒绝后检查 App 内的设置路径和「重新检查」。在「系统设置 → 隐私与安全性 → 本地网络」重新允许后复查，记录是否需要重启 App，以及重新出现的设备和成功传输结果。 [Apple 局域网权限说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [ ] **防火墙允许和拒绝**。在受信任的测试网络中，从「系统设置 → 网络 → 防火墙 → 选项」为本次验证的 `NearTransfer.app` 切换阻止和允许传入连接。分别记录设备能否发现、请求或反向校验能否建立、允许后能否恢复双向收发。 [Apple 防火墙设置](https://support.apple.com/guide/mac-help/change-firewall-settings-on-mac-mh11783/mac)

若设备发现失败，可用 `dns-sd -B _neartransfer._tcp local.` 查看广播，用 `dns-sd -L "<服务实例名>" _neartransfer._tcp local.` 核对端口和 TXT，再比对两端 App 的设备列表。权限以访达启动 App 的实际表现为准。

## 签名、分发与许可证

1. 构建 Release 后用 Xcode 打开 `macos/Runner.xcworkspace`。在协作者的本地发布配置中，为 Runner 的 Release 选择自己的 Apple Team 和 Developer ID Application 签名身份，保留 Release entitlements 并启用 Hardened Runtime。证书、私钥、配置文件和公证凭据保存在仓库外。
2. 选择 Runner scheme，执行 **Product → Archive**。在 Organizer 中选 **Distribute App → Developer ID**，提交 Apple 公证并导出附有公证票据的 App。若使用 `xcrun notarytool`，先验证提交结果，再用 `xcrun stapler staple` 附票。 [Apple 签名与公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
3. 运行 `codesign --verify --deep --strict "<导出的 NearTransfer.app>"` 和 `xcrun stapler validate "<导出的 NearTransfer.app>"`。用 `ditto -c -k --sequesterRsrc --keepParent "<导出的 NearTransfer.app>" NearTransfer-macOS.zip` 打包。在干净的 Mac 账户下载、解包并从访达启动，复验权限及一轮双向收发，记录 ZIP 的 SHA-256。 [Apple macOS 打包说明](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

本地仓库未发现项目 `LICENSE`、`COPYING` 或项目许可证声明。依赖各有许可证，正式分发前由项目所有者确认本项目的发布授权，并核对随包所需的第三方许可证和版权声明。本次未添加项目许可证。
