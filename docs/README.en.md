<p align="center">
  <img src="../macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="96" alt="NearTransfer icon">
</p>
<h1 align="center">NearTransfer</h1>
<p align="center">Share files on your local network.</p>

<p align="center">
  <a href="../README.md"><img src="https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-176D56?style=for-the-badge" alt="简体中文"></a>
  <a href="README.en.md"><img src="https://img.shields.io/badge/English-176D56?style=for-the-badge" alt="English"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-176D56?style=for-the-badge" alt="日本語"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Fran%C3%A7ais-176D56?style=for-the-badge" alt="Français"></a>
  <a href="README.es.md"><img src="https://img.shields.io/badge/Espa%C3%B1ol-176D56?style=for-the-badge" alt="Español"></a>
</p>

NearTransfer is a local-network file transfer tool. Connect your devices to the same IPv4 network, select files and a nearby device, and let the recipient accept the request. No account or internet connection is required during use.

- **Discover nearby devices** and see a marker on devices you have successfully transferred files with before.
- **Send multiple files** after the recipient accepts. Incoming files with the same name receive a numbered suffix.
- **Transfer directly over HTTPS** between devices. File size and SHA-256 are checked during reception.
- **Use a familiar interface** with drag and drop and a system tray on Windows. The Flutter app offers Chinese, English, Japanese, French and Spanish.

## Versions and downloads

| Platform | Current status |
| --- | --- |
| Windows 11 x64 | A standalone preview EXE is available. [Download for Windows](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Windows-x64.exe) |
| Android 10 and later | A preview APK is available. [Download for Android](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Android.apk) |
| iOS / iPadOS | No finished app is available. The design and experimental source are provided for you to build and validate. [Development and validation](../技术方案/iOS开发与验收.md) |
| macOS | No finished app is available. The design and experimental source are provided for you to build and validate. [Development and validation](../技术方案/macOS开发与验收.md) |
| HarmonyOS NEXT | No finished app is available. The design and experimental source are provided for you to build and validate. [Development and validation](../技术方案/HarmonyOS开发与验收.md) |

The Windows and Android preview packages were rebuilt from the integrated source. Earlier Windows and Android builds transferred photos and documents in both directions. The rebuilt APK still needs device acceptance testing, along with additional device and network coverage. [Release page](https://github.com/Tintinding/NearTransfer/releases/tag/v1.0.0-preview)

## Get started

1. Install or open the preview on a Windows computer and an Android phone.
2. Connect both devices to the same IPv4 local network and keep NearTransfer running on both.
3. Choose files and a nearby device on the sender, then select **Send**. Accept the request on the receiving device.
4. Find received files in the system Downloads folder.

## Build from source

The Flutter interface and Dart transfer core are in `lib/`. Platform projects are in `windows/`, `android/`, `ios/` and `macos/`. The HarmonyOS native project is in `harmonyos/`. Build scripts are in `tool/` and tests are in `test/`.

The detailed [build instructions](../README.md#开发与构建) and [platform plans](../技术方案/公共技术方案.md) are currently in Chinese.
