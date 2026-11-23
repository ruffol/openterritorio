# OPENTERITORIO · app Flutter (Fase B)

Cliente táctico del backend del teléfono. Estado: **completa y compilada**.

## Qué incluye

- `lib/protocol/tactical_packet.dart` — Protobuf a mano (sin `protoc`):
  posición, evento, alerta y ACK. Los bytes se fijan contra vectores generados
  con `protobufjs`, el mismo decoder del servidor.
- `lib/data/backend_client.dart` — WebSocket binario con reconexión exponencial
  (1–30 s con jitter), cola acotada a 90 s, token en el handshake y REST
  `/api/state` con `Bearer`.
- `lib/data/app_state.dart` — estado observable (pares, eventos, alertas,
  posición propia) con deduplicación por `packet_id` y carga de la foto REST.
- `lib/ui/board.dart` — tablero 100 % Dart (`CustomPainter`): rumbo, radios de
  alerta, rejilla, escala y coordenadas.
- `lib/ui/home_page.dart` — orquesta conexión, GPS real (`geolocator`), envío
  adaptativo cada 5 s, ACK automático de alertas, botón **SIM** y OTA.
- `lib/ui/connection_dialog.dart`, `lib/ui/event_dialog.dart` y
  `lib/ui/status_bar.dart` — diálogos de conexión/evento y pie de estado
  extraídos de la pantalla principal.
- `lib/data/connection_settings.dart` — persistencia tipada de URL, token y
  `sender_id` estable (se genera una sola vez y se guarda).
- `lib/util/utf8_truncate.dart` — recorte de notas a 64 bytes UTF-8 sin partir
  caracteres multibyte.
- `lib/data/ota_*.dart` + `lib/ui/update_dialog.dart` — **actualizaciones OTA**:
  consulta `/api/app/latest`, descarga el APK con token, verifica el sha256 y lo
  instala con `PackageInstaller` (canal nativo `openterritorio/ota`).
- Material UI mediante el paquete oficial `material_ui` (en Flutter 3.50
  `package:flutter/material.dart` está deprecado).

## Estado verificado

| Comprobación | Resultado |
| --- | --- |
| `flutter analyze` | sin incidencias |
| `flutter test` | **23/23** |
| `flutter build apk --release` (universal) | **OK** |

APK: `build/app/outputs/flutter-apk/app-release.apk` (**49,6 MB universal**:
armv7, arm64 y x86_64), `minSdk 34` / `targetSdk 36`. Toolchain: Flutter 3.50.1,
Gradle 9.5, AGP 9.3.1, Kotlin 2.4.20.

> No uses `--target-platform android-arm` con AGP 9: el APK acaba anunciando
> `arm64-v8a` (por las librerías de los plugins) sin `libflutter.so` de 64 bits,
> y en un teléfono de 64 bits Android lo instala en 64 bits y **se cierra al
> arrancar**. El APK universal evita ese problema.

## Compilar

Requisitos: **Android 14 (API 34) o superior**, Flutter 3.50.1 (Dart 3.14),
JDK 17 y Android SDK 36. El wrapper de Gradle 9.5 se versiona en `android/`, así
que no hace falta instalar Gradle.

```powershell
cd app
flutter pub get
flutter build apk --release
```

Si Flutter detecta un JDK demasiado nuevo (p. ej. el JBR de Android Studio con
Java 25), apunta al JDK 17:

```powershell
flutter config --jdk-dir "C:\ruta\a\jdk-17"
```

Valores por defecto editables con `--dart-define` (también desde la pantalla de
conexión, que los persiste):

```powershell
flutter build apk --release `
  --dart-define=OPENTERITORIO_URL=http://127.0.0.1:3000 `
  --dart-define=OPENTERITORIO_TOKEN=<TOKEN>
```

Instalar en el Q524:

```powershell
adb install -r build\app\outputs\flutter-apk\app-release.apk
adb shell am start -n com.openterritorio.openterritorio/.MainActivity
```

La app corre **en el mismo teléfono** que el backend; por eso el servidor por
defecto es `http://127.0.0.1:3000`. Para un segundo teléfono, usa
`http://192.168.100.3:3000` o la URL pública.

## Pruebas

```powershell
flutter analyze
flutter test
```

- `test/protocol_test.dart` — byte a byte contra vectores de `protobufjs`,
  decodificación de los paquetes del servidor, coordenadas negativas, estado y
  deduplicación, y snapshot de `/api/state`.
- `test/backend_client_test.dart` — WebSocket y REST reales contra un backend de
  prueba en loopback: handshake con token, envío/recepción binaria y 401.
- `test/connection_settings_test.dart` — valores por defecto, `sender_id`
  estable entre arranques y round-trip de guardado.
- `test/utf8_truncate_test.dart` — recorte de notas sin partir caracteres de
  varios bytes (acentos y emoji).
- `test/ota_service_test.dart` — metadata, descarga autenticada, sha256
  correcto/incorrecto, instalación inyectada y 404 sin publicación.

## Probar contra el backend real

```powershell
dart run tool/wire_check.dart http://127.0.0.1:3000 <TOKEN>
```

Envía una posición, comprueba que aparece en `/api/state`, publica una alerta
por REST, la recibe por WebSocket y responde con `ACK_CONFIRMATION` (verifica
que el servidor lo registra). Es la misma ruta de código que usa la app.

## Actualizaciones OTA

La app consulta `GET /api/app/latest` al arrancar (y con el botón de la barra
superior). Si `version_code` es mayor que el instalado muestra las notas, y al
aceptar descarga `/api/app/download` con el token, **verifica el sha256** y abre
el instalador del sistema.

- La primera vez Android pide permitir "instalar apps desconocidas" para
  OPENTERITORIO; la app abre ese ajuste si falta.
- El APK debe estar firmado con la **misma clave** que la versión instalada.
  `android/key.properties` (no versionado) activa la firma de release; sin él se
  usa la debug key del PC. En CI se configuran los secrets
  `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` y
  `ANDROID_KEY_PASSWORD` (ver workflow).
- Publicar: `tools\publish-apk.ps1` (compila, calcula sha256, sube APK y
  `latest.json` al teléfono); el watcher los sirve en ≤ 10 s.

## Si la app se cierra al arrancar

- Este APK es **universal**. Si antes instalaste un APK de CI (firma distinta)
  desinstala primero; el instalador rechaza firmas diferentes.
- La app escribe `Descargas/openterritorio-crash.txt` con el stack y las ABIs
  reales del teléfono (capturador `CrashApplication`).
- Con USB: `adb install -r build\app\outputs\flutter-apk\app-release.apk` y
  `adb logcat -b crash` para ver el error completo.
- Impeller está desactivado en el manifiesto (`EnableImpeller=false`): las GPU
  Mali-400/GLES 2.0 de equipos como el Q524 han provocado cierres en Flutter
  3.4x/3.5x. Si se reactiva, hazlo solo tras probar en el teléfono.

## Siguiente iteración

- Mapa vectorial offline con PMTiles/MBTiles y `maplibre_gl`.
- Android Foreground Service para rastreo con pantalla apagada.
- Adaptadores BLE, USB serial, malla (Nearby) y audio AFSK del PDF (fases 4–5).
