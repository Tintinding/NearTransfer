<p align="center">
  <img src="../macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="96" alt="Icône de NearTransfer">
</p>
<h1 align="center">NearTransfer</h1>
<p align="center">Partagez vos fichiers sur votre réseau local.</p>

<p align="center">
  <a href="../README.md"><img src="https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-176D56?style=for-the-badge" alt="简体中文"></a>
  <a href="README.en.md"><img src="https://img.shields.io/badge/English-176D56?style=for-the-badge" alt="English"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-176D56?style=for-the-badge" alt="日本語"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Fran%C3%A7ais-176D56?style=for-the-badge" alt="Français"></a>
  <a href="README.es.md"><img src="https://img.shields.io/badge/Espa%C3%B1ol-176D56?style=for-the-badge" alt="Español"></a>
</p>

NearTransfer permet de transférer des fichiers sur un réseau local. Connectez vos appareils au même réseau IPv4, choisissez les fichiers et un appareil à proximité, puis laissez le destinataire accepter la demande. Aucun compte ni connexion Internet n'est nécessaire pendant l'utilisation.

- **Détectez les appareils à proximité** et retrouvez un repère sur ceux avec lesquels un transfert a déjà réussi.
- **Envoyez plusieurs fichiers** après confirmation du destinataire. Les fichiers reçus portant le même nom sont numérotés.
- **Transférez directement en HTTPS** entre appareils, avec vérification de la taille et du SHA-256 à la réception.
- Sous Windows, utilisez le glisser-déposer et la zone de notification. L'interface Flutter est disponible en chinois, anglais, japonais, français et espagnol.

## Versions et téléchargements

| Plateforme | État actuel |
| --- | --- |
| Windows 11 x64 | Une version d'essai sous forme d'EXE autonome est disponible. [Télécharger pour Windows](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Windows-x64.exe) |
| Android 10 et versions ultérieures | Un APK d'essai est disponible. [Télécharger pour Android](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Android.apk) |
| iOS / iPadOS | Aucune application finalisée n'est disponible. Le principe et le code expérimental sont fournis pour que vous puissiez les compiler et les vérifier vous-même. [Développement et validation](../技术方案/iOS开发与验收.md) |
| macOS | Aucune application finalisée n'est disponible. Le principe et le code expérimental sont fournis pour que vous puissiez les compiler et les vérifier vous-même. [Développement et validation](../技术方案/macOS开发与验收.md) |
| HarmonyOS NEXT | Aucune application finalisée n'est disponible. Le principe et le code expérimental sont fournis pour que vous puissiez les compiler et les vérifier vous-même. [Développement et validation](../技术方案/HarmonyOS开发与验收.md) |

Les versions d'essai Windows et Android ont été reconstruites à partir du code intégré. Des versions antérieures ont permis de tester le transfert de photos et de documents dans les deux sens entre Windows et Android. L'APK reconstruit doit encore être validé sur appareil, ainsi que sur d'autres appareils et réseaux. [Page de publication](https://github.com/Tintinding/NearTransfer/releases/tag/v1.0.0-preview)

## Premiers pas

1. Installez ou ouvrez la version d'essai sur un ordinateur Windows et un téléphone Android.
2. Connectez les deux appareils au même réseau local IPv4 et laissez NearTransfer ouvert sur chacun.
3. Sur l'appareil émetteur, choisissez les fichiers et un appareil à proximité, puis appuyez sur **Envoyer**. Acceptez la demande sur l'appareil destinataire.
4. Retrouvez les fichiers reçus dans le dossier Téléchargements du système.

## Compiler depuis le code source

L'interface Flutter et le cœur de transfert Dart se trouvent dans `lib/`. Les projets de plateforme se trouvent dans `windows/`, `android/`, `ios/`, `macos/` et `harmonyos/`. Les scripts de compilation sont dans `tool/` et les tests dans `test/`.

Les [instructions de compilation](../README.md#开发与构建) et la [documentation technique](../技术方案/公共技术方案.md) détaillées sont actuellement en chinois.
