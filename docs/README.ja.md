<p align="center">
  <img src="../macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="96" alt="NearTransfer のアイコン">
</p>
<h1 align="center">NearTransfer</h1>
<p align="center">同じローカルネットワーク内でファイルを送受信。</p>

<p align="center">
  <a href="../README.md"><img src="https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-176D56?style=for-the-badge" alt="简体中文"></a>
  <a href="README.en.md"><img src="https://img.shields.io/badge/English-176D56?style=for-the-badge" alt="English"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-176D56?style=for-the-badge" alt="日本語"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Fran%C3%A7ais-176D56?style=for-the-badge" alt="Français"></a>
  <a href="README.es.md"><img src="https://img.shields.io/badge/Espa%C3%B1ol-176D56?style=for-the-badge" alt="Español"></a>
</p>

NearTransfer は、ローカルネットワーク上でファイルを転送するツールです。端末を同じ IPv4 ネットワークに接続し、ファイルと近くの端末を選択します。受信側が承認すると転送が始まります。使用時にアカウントやインターネット接続は必要ありません。

- **近くの端末を検出**し、以前に転送が成功した端末にはマークを表示します。
- **複数ファイルを送信**できます。受信先に同名ファイルがある場合は番号を付けて保存します。
- **端末間を HTTPS で直接転送**し、受信時にサイズと SHA-256 を検証します。
- Windows ではドラッグ＆ドロップとシステムトレイに対応します。Flutter 版の表示言語は中国語、英語、日本語、フランス語、スペイン語から選べます。

## 版とダウンロード

| プラットフォーム | 現在の状況 |
| --- | --- |
| Windows 11 x64 | 単一 EXE のプレビュー版を提供しています。 [Windows 版をダウンロード](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Windows-x64.exe) |
| Android 10 以降 | APK のプレビュー版を提供しています。 [Android 版をダウンロード](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Android.apk) |
| iOS / iPadOS | 完成版はありません。実装の考え方と実験的なソースを提供しており、ご自身でビルドと検証が必要です。 [開発と検証](../技术方案/iOS开发与验收.md) |
| macOS | 完成版はありません。実装の考え方と実験的なソースを提供しており、ご自身でビルドと検証が必要です。 [開発と検証](../技术方案/macOS开发与验收.md) |
| HarmonyOS NEXT | 完成版はありません。実装の考え方と実験的なソースを提供しており、ご自身でビルドと検証が必要です。 [開発と検証](../技术方案/HarmonyOS开发与验收.md) |

Windows と Android のプレビュー版は、統合後のソースから再ビルドしました。以前の版では、Windows と Android の間で写真と文書の双方向転送をテストしました。再ビルドした APK の実機受け入れテストと、より多くの端末・ネットワークでの検証は今後必要です。 [リリースページ](https://github.com/Tintinding/NearTransfer/releases/tag/v1.0.0-preview)

## 使い方

1. Windows パソコンと Android スマートフォンで、それぞれのプレビュー版をインストールまたは起動します。
2. 両端末を同じ IPv4 ローカルネットワークに接続し、NearTransfer を起動したままにします。
3. 送信側でファイルと近くの端末を選び、「送信」を押します。受信側でリクエストを承認します。
4. 転送後、システムの「ダウンロード」フォルダーでファイルを確認します。

## ソースからのビルド

Flutter の画面と Dart の転送コアは `lib/` にあります。各プラットフォームのプロジェクトは `windows/`、`android/`、`ios/`、`macos/`、`harmonyos/` にあります。ビルドスクリプトは `tool/`、テストは `test/` にあります。

詳細な[ビルド手順](../README.md#开发与构建)と[技術資料](../技术方案/公共技术方案.md)は中国語で記載しています。
