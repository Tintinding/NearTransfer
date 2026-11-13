# 近传 · Android 开发方案

Android App 使用 Flutter 界面、Dart 收发核心和必要的 Kotlin 系统桥接。建议首版从 **Android 10（API 29）** 起支持，便于直接使用 `MediaStore.Downloads`。实际目标 API 随 Flutter、发布渠道和权限要求确定。共用接口、设备身份和协议见[公共技术方案](公共技术方案.md)。

## 平台实现

| 功能 | 实现 |
| --- | --- |
| 选择文件 | 用 Storage Access Framework 的 `ACTION_OPEN_DOCUMENT` 打开系统选择器，支持多选。通过 `ContentResolver` 读取文件名、大小与流。将 `content://` URI 视为文件句柄。若文档提供方无法给出大小、文件无法离线读取或授权失效，提示重选本地文件。 [Android 文档选择](https://developer.android.com/training/data-storage/shared/documents-files) |
| 文件读取 | Kotlin 在后台线程打开和读取 URI，Dart 按需请求有大小上限的数据块。发送端计算摘要和上传时各自重新打开流。取消、结束或异常时关闭流，并验证本地大视频在读取时不会导致内存随文件大小增长。 |
| 保存到 Downloads | 用 `MediaStore.Downloads` 创建条目，写入前设 `IS_PENDING=1`，长度与摘要通过后解除待发布状态。失败或取消时删除本次创建的待发布条目。记录未发布的 URI，用于 App 重启后清理本应用的残留项。验证同名自动编号及原有文件不被覆盖，展示系统最终采用的文件名。 [Android 共享存储](https://developer.android.com/training/data-storage/shared/media) |
| 打开文件和查看位置 | 保留已提交的 URI，用系统 Intent 打开，按需向目标 App 临时授予读权限。详情展示下载目录和实际文件名。设备无法直接打开下载目录时，仍可从系统文件 App 的「下载」查看。 |
| 设备发现与权限 | 接入共享发现接口，发布和查找同一服务。插件不满足 Android 真机测试时用 `NsdManager`。在 release 清单中声明 `INTERNET` 以使用网络套接字。若以 Android 17（API 37）或更高版本为目标，按系统要求申请局域网权限，分别验证允许与拒绝。 [Android NSD](https://developer.android.com/develop/connectivity/wifi/use-nsd) · [局域网权限](https://developer.android.com/privacy-and-security/local-network-permission) |
| 应用生命周期 | 首版在 App 打开时提供发现和收发。网络切换或回到前台时重新检查监听和发现。离开前台、锁屏或系统杀进程导致中断时，按共享规则保留已提交项，恢复后更新结果。 |

## 开发顺序

1. **A1 · 文件选择和保存。** 完成选择器、URI 流、Downloads 临时写入、提交、清理和打开。用本机文件验证中文名、同名、空文件、大文件与存储不足。
2. **A2 · 发现和连接。** 在 Android 真机与 PC 测试对端之间验证双向发现和 HTTPS 连接。切换 Wi-Fi 后验证失效设备消失并重新发现。覆盖权限被拒绝和设备离线。
3. **A3 · 完整收发。** 把平台文件接口接入共享页面，验证发送、逐次确认、进度、拒绝、取消和只重试失败项。先与测试对端验收，再与 Windows App 联调。
4. **A4 · 发布包。** 用 `flutter analyze` 和 `flutter test` 检查代码，用 `flutter run` 在真机调试，用 `flutter build apk --release` 生成签名 APK。签名配置从本机或构建环境注入，密钥和密码留在仓库外。首版交付 APK。 [Flutter Android 发布](https://docs.flutter.dev/deployment/android)

## Android 验收

- [ ] 真机点击右上角「ZH ⇄ EN」打开语言菜单。菜单依次列出 English、简体中文、日本語、Français 和 Español，并勾选当前语言。选择后立即更新界面，重启后恢复所选语言。系统文件选择器的系统控件使用 Android 系统语言。
- [x] 与 Windows 真机双向互传照片和文档，均成功（2026-11-12；具体设备型号、文件完整性校验及网络条件未记录）。
- [ ] 真机安装签名 APK 并正常启动，release 包可以在同一局域网发现 PC 并收发。
- [ ] 系统选择器能选单文件和多文件。取消选择或 URI 不再可读时有明确反馈。
- [ ] 接收文件在系统 Downloads 可找到，中文名正常，同名文件自动编号且均可打开。
- [ ] 传大视频时内存占用不随文件大小线性增长，落盘大小和 SHA-256 与源文件一致。
- [ ] 批量传到第二个文件时断网或取消，保留已提交项、删除待发布项。恢复后重试失败项。
- [ ] 首次收到请求必须确认。拒绝、超时、局域网权限被拒绝时，页面给出对应提示。
