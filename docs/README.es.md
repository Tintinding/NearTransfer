<p align="center">
  <img src="../macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="96" alt="Icono de NearTransfer">
</p>
<h1 align="center">NearTransfer</h1>
<p align="center">Comparte archivos en tu red local.</p>

<p align="center">
  <a href="../README.md"><img src="https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-176D56?style=for-the-badge" alt="简体中文"></a>
  <a href="README.en.md"><img src="https://img.shields.io/badge/English-176D56?style=for-the-badge" alt="English"></a>
  <a href="README.ja.md"><img src="https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-176D56?style=for-the-badge" alt="日本語"></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/Fran%C3%A7ais-176D56?style=for-the-badge" alt="Français"></a>
  <a href="README.es.md"><img src="https://img.shields.io/badge/Espa%C3%B1ol-176D56?style=for-the-badge" alt="Español"></a>
</p>

NearTransfer es una herramienta para transferir archivos por la red local. Conecta los dispositivos a la misma red IPv4, selecciona los archivos y un dispositivo cercano, y espera a que el destinatario acepte la solicitud. No necesitas una cuenta ni conexión a Internet durante el uso.

- **Descubre dispositivos cercanos** y reconoce los dispositivos con los que ya completaste una transferencia.
- **Envía varios archivos** tras la confirmación del destinatario. Los archivos recibidos con nombres repetidos se numeran.
- **Transfiere directamente mediante HTTPS** entre dispositivos. Al recibir se comprueban el tamaño y el SHA-256.
- En Windows puedes arrastrar archivos y usar la bandeja del sistema. La interfaz Flutter está disponible en chino, inglés, japonés, francés y español.

## Versiones y descargas

| Plataforma | Estado actual |
| --- | --- |
| Windows 11 x64 | Hay un EXE independiente de prueba. [Descargar para Windows](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Windows-x64.exe) |
| Android 10 y posteriores | Hay un APK de prueba. [Descargar para Android](https://github.com/Tintinding/NearTransfer/releases/download/v1.0.0-preview/NearTransfer-Android.apk) |
| iOS / iPadOS | Aún no hay una aplicación terminada. Se proporcionan el planteamiento y código experimental para que los compiles y valides por tu cuenta. [Desarrollo y validación](../技术方案/iOS开发与验收.md) |
| macOS | Aún no hay una aplicación terminada. Se proporcionan el planteamiento y código experimental para que los compiles y valides por tu cuenta. [Desarrollo y validación](../技术方案/macOS开发与验收.md) |
| HarmonyOS NEXT | Aún no hay una aplicación terminada. Se proporcionan el planteamiento y código experimental para que los compiles y valides por tu cuenta. [Desarrollo y validación](../技术方案/HarmonyOS开发与验收.md) |

Los paquetes de Windows y Android son versiones de prueba creadas antes de integrar el código de las demás plataformas. Se han probado transferencias en ambos sentidos entre Windows y Android. Aún queda pendiente la validación del APK publicado en un dispositivo y la prueba en más dispositivos y redes. [Página de la versión](https://github.com/Tintinding/NearTransfer/releases/tag/v1.0.0-preview)

## Primeros pasos

1. Instala o abre la versión de prueba en un ordenador Windows y un teléfono Android.
2. Conecta ambos dispositivos a la misma red local IPv4 y mantén NearTransfer abierto en los dos.
3. En el emisor, selecciona los archivos y un dispositivo cercano y pulsa **Enviar**. Acepta la solicitud en el dispositivo receptor.
4. Busca los archivos recibidos en la carpeta Descargas del sistema.

## Compilar desde el código fuente

La interfaz Flutter y el núcleo de transferencia Dart están en `lib/`. Los proyectos de cada plataforma están en `windows/`, `android/`, `ios/`, `macos/` y `harmonyos/`. Los scripts de compilación están en `tool/` y las pruebas en `test/`.

Las [instrucciones de compilación](../README.md#开发与构建) y la [documentación técnica](../技术方案/公共技术方案.md) detalladas están actualmente en chino.
