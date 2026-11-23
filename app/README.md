# OPENTERITORIO · app Flutter (Fase B)

Cliente táctico mínimo para el backend del teléfono.

## Qué incluye

- Protocolo Protobuf implementado a mano (sin `protoc`) en
  `lib/protocol/tactical_packet.dart` (posición, evento, alerta y ACK).
- Cliente WebSocket con reconexión exponencial y REST `/api/state`.
- Tablero táctico 100 % Dart (`CustomPainter`): pares con rumbo, eventos,
  alertas con radio, posición propia, rejilla, escala y coordenadas.
- Pantalla de conexión: URL, token e ID de dispositivo.
- Botón **SIM** para generar una posición en movimiento (Colima) cuando no hay
  GPS; la app envía un `POSITION_UPDATE` cada 5 s.

## Estado

- `flutter analyze`: sin errores (solo avisos de deprecación de Flutter 3.50).
- **APK pendiente de compilar** en este PC: el toolchain está instalado
  (Flutter 3.50.1, JDK 17, SDK 36, NDK 28.2.13676358), pero Gradle 9.5/AGP 9
  resultó demasiado lento/inestable en esta máquina y la descarga de artefactos
  del motor se atasca. El código está listo para `flutter build apk`.
- `geolocator` y `shared_preferences` se retiraron: sus versiones actuales no
  compilan con AGP 9 (`compileSdkVersion`/`jni` incompatibles). Por eso el GPS
  real queda para una integración posterior (canal nativo o versión compatible)
  y la configuración no persiste entre reinicios (usa `--dart-define`).

## Compilar

Requisitos: Flutter 3.50+, JDK 17, Android SDK 36 y NDK 28.2.13676358.

```powershell
cd app
flutter pub get
flutter build apk --release --target-platform android-arm `
  --dart-define=OPENTERITORIO_URL=http://127.0.0.1:3000 `
  --dart-define=OPENTERITORIO_TOKEN=<TOKEN>
```

Instalar en el Q524:

```powershell
adb install -r build\app\outputs\flutter-apk\app-release.apk
adb shell am start -n com.openterritorio.openterritorio/.MainActivity
```

La app corre **en el mismo teléfono** que el backend; por eso el servidor por
defecto es `http://127.0.0.1:3000`. Para un segundo teléfono, cambia la URL a
`http://192.168.100.3:3000` o a la URL pública.

## Siguiente iteración

- Mapa vectorial con PMTiles/MBTiles y `maplibre_gl`.
- GPS real con `geolocator` en una versión compatible o canal nativo.
- Persistencia de ajustes (archivo propio o versión de `shared_preferences`
  compatible con AGP 9).
