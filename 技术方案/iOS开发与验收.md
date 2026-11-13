# 近传 · iOS 与 iPadOS 开发与验收

## 实现与依赖

- 同一个 `ios/Runner` 目标支持 iOS 和 iPadOS 15.0 及以上版本。Swift 提供系统选档、局域网权限状态、文件预览和导出。Flutter 端通过 `lib/ios_bridge.dart` 接入共享页面和 Dart 收发核心。
- 从「文件」多选时，近传在文件提供者授权期间复制所选文件，发送和重试从 App 私有副本分块读取。云端文件可能需要先下载，导入需要本机可用空间。
- 校验通过后，接收文件出现在「文件 › 浏览 › 我的 iPhone 或我的 iPad › 近传 › Received」。在结果页可用「打开」预览或用「导出」另存副本。宽窗口并排显示文件和设备，窄窗口上下排列。收到请求时，确认窗可滚动查看清单。

## 模拟器构建

工作流固定 Flutter 3.50.0（Dart 3.14.0）和 Xcode 26.6。首次安装 Xcode 后打开一次并完成设置，在 Components 中安装 iOS Simulator 运行时。Flutter 通过 Swift Package Manager 准备原生依赖。在 Mac 上从仓库根目录运行以下命令。 [Flutter SDK 下载](https://docs.flutter.dev/install/archive) · [Flutter iOS 环境](https://docs.flutter.dev/platform-integration/ios/setup)

```bash
flutter doctor -v
flutter pub get --enforce-lockfile
flutter gen-l10n
open -a Simulator
flutter devices
flutter run -d SIMULATOR_ID
```

将 `SIMULATOR_ID` 替换为 `flutter devices` 中的设备 ID。可以在 Simulator 的设备菜单中选择 iPhone 或 iPad，检查启动、页面布局和旋转。局域网隐私权限在真机上测试。 [Apple 本地网络隐私](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

**iOS Simulator** 工作流在推送到 `main` 或 `master`、新建或更新 PR 时运行，也支持在 GitHub Actions 手动运行。构建成功会提供 `NearTransfer-iOS-Simulator-arm64.zip`。在 Apple 芯片的 Mac 上解压后，可以用 `xcrun simctl install booted Runner.app` 安装到已启动的模拟器。集成版本的云端构建待验证，请记录工作流链接、提交 SHA、Flutter 和 Xcode 版本及结果。 [工作流](../.github/workflows/ios-simulator.yml)

## 真机安装

1. 在仓库根目录运行 `flutter build ios --config-only --debug --no-codesign`，再运行 `open ios/Runner.xcworkspace`。
2. 在 Xcode 的 **Settings → Accounts** 添加 Apple Account。在 **Runner target → Signing & Capabilities** 勾选 **Automatically manage signing**，选择自己的 **Personal Team**。若示例 Bundle Identifier `app.neartransfer.nearTransfer` 无法注册，在本地改成团队可用的唯一标识。
3. 连接并信任 iPhone 或 iPad，按系统提示开启「设置 › 隐私与安全性 › 开发者模式」。在 Xcode 选择 **Runner** 和实际设备，点击 **Run**。个人团队、临时 Bundle Identifier 和签名设置留在协作者本机。 [Apple 开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## 真机验收

优先用现有 Windows App 作对端。也可用 Android App 或 [Dart 测试端](../README.md#与-windows-测试端双向验收)。双方接入同一支持 Bonjour 的 IPv4 局域网，保持移动端近传在前台。

| 记录项 | iPhone | iPad |
| --- | --- | --- |
| 型号和系统版本 | 待填写 | 待填写 |
| 测试日期、近传提交 SHA（TestFlight 同时记录构建号） | 待填写 | 待填写 |
| 对端平台、型号或系统版本、App 版本或提交 SHA | 待填写 | 待填写 |

逐项填写通过、失败或未测。失败时附 Issue 链接。

| 检查项 | 操作和预期 | iPhone | iPad |
| --- | --- | --- | --- |
| 本地网络拒绝和允许 | 初次启动选择拒绝，检查页面提示且双方无法发现。到「设置 › 隐私与安全性 › 本地网络」允许近传，返回后重新检查。用重新安装验证首次直接允许。 | 待测 | 待测 |
| 双向发现和收发 | 两端都能发现对方，各成功发送一次文件。关闭外网、保留局域网再测一次。对端退出后应从附近设备移除，再打开后仍显示「传过文件」。 | 待测 | 待测 |
| 多选、取消和导出 | 从「文件」选多个普通文件，取消选档时原列表保留。接收后用近传预览常见格式，导出副本到另一个目录，并在「近传 › Received」查看原件。 | 待测 | 待测 |
| 语言切换 | 点击右上角「ZH ⇄ EN」，逐项切换五种语言并检查勾选。重启后检查语言仍为上次所选，确认接收弹窗、导出及保存位置提示随 App 语言切换。 | 待测 | 待测 |
| 接收确认 | 发送后核对弹窗中的设备名、清单和总大小。等待和拒绝时没有落盘文件。再发一次，点「接受」后两端显示进度。 | 待测 | 待测 |
| 中文名、空文件和同名 | 双向传输中文名文件和空文件。向已有同名文件的端再发一次，核对原件内容、新文件编号和空文件大小。 | 待测 | 待测 |
| 大文件完整性 | 双向各传一个超过 2 GiB 的文件，对比源文件和接收文件的 SHA-256。保留字节数及摘要，Windows 可用 `Get-FileHash -Algorithm SHA256`，Mac 可用 `shasum -a 256`。 | 待测 | 待测 |
| 取消、清理和重试 | 在第二个文件上传中取消。两端核对第一个文件仍在，第二个文件没有发布。重试时只提交未完成项，并再次要求确认。退出重开后检查接收目录，必要时用 Xcode 下载 App 容器检查接收缓存。 | 待测 | 待测 |
| 切换到后台后返回 | 传输中锁屏或切到其他 App，返回后重新发现，核对已保存文件和失败项重试。 | 待测 | 待测 |
| 横屏与分屏 | 横屏检查文件和设备列表，缩窄窗口或进入分屏后检查列表滚动、选中状态以及多文件确认窗的两个按钮。 | 横屏待测 | 横屏和分屏待测 |

提交 Issue 或 PR 时附上表中环境信息、复现步骤、预期与实际结果，标明发送方向和文件大小。

## 维护者签名与 TestFlight

1. 在 Apple Developer Program 团队下注册正式 Bundle ID，在 App Store Connect 建立对应 App。使用具备签名和上传权限的团队账号，在 Runner 中选择该团队与正式 Bundle ID，配置发行签名。
2. 在 Mac 的仓库根目录运行 `flutter build ipa --release --build-name 1.0.0 --build-number 2`。把版本和构建号替换成这次的值，每次上传递增构建号。归档位于 `build/ios/archive/`，签名 IPA 位于 `build/ios/ipa/`。
3. 用 Transporter 上传 IPA，或在 Xcode Organizer 中选中归档，通过 **Distribute App → App Store Connect** 上传。处理完成后，在 **App Store Connect → TestFlight** 按实际加密用途填写出口合规信息，将该构建分配给内部测试组。邀请外部测试者时，按 Apple 要求提交 Beta App Review。 [Flutter iOS 分发](https://docs.flutter.dev/deployment/ios) · [Apple 上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) · [TestFlight](https://developer.apple.com/testflight/) · [Apple 加密出口合规](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)

签名密钥、描述文件和证书保存在仓库外。公开分发前，由维护者确认项目授权和依赖许可证。
