# OPENTERITORIO — backend táctico en el teléfono

Implementación de la **Fase A** del proyecto descrito en
[`docs/especificacion.pdf`](docs/especificacion.pdf): el backend offline-first
de mapas, rastreo GPS y eventos multi-transporte corre **en el propio teléfono**
(FISE Q524, Android 14) y se publica por el túnel Cloudflare que ya existía.

## Estado

| Componente | Valor |
| --- | --- |
| URL pública | <https://tienda.tlalchichi.xyz> |
| WebSocket | `wss://tienda.tlalchichi.xyz/ws?token=…` |
| LAN | `http://192.168.100.3:3000` |
| Servicios | runit `openterritorio` + `openterritorio-deploy` (Termux) |
| Datos | SQLite `~/openterritorio/data/tactical.db` |
| Token | `backup/token.txt` (no versionado) y `~/openterritorio/.env` (chmod 600) |
| Tienda anterior | respaldada en `backup/` y retirada del teléfono |

> El túnel `cloudflared`, el dominio y sus credenciales se conservaron sin
> cambios; solo cambió el proceso que escucha en `:3000`.

## Qué hay en el repo

- `proto/tactical_packet.proto` — contrato binario (sección 5 del PDF) + ACK.
- `server/` — Node.js + Express + `ws` + protobufjs + `node:sqlite`.
- `server/public/` — panel de operador: pares, eventos y alertas.
- `app/` — cliente Flutter (protocolo, WebSocket/REST, tablero, GPS, eventos).
- `termux/` — bootstrap, instalación, watcher de despliegue y limpieza.
- `tools/` — despliegue del backend, salud, SSH y publicación de APK (OTA).
- `docs/` — arquitectura, protocolo, runbook, pruebas y estado del teléfono.

## Arranque rápido (PC)

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\health.ps1 -Port 3000 -Public
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -Port 3000
```

Despliegue = tests + tarball + `adb push` + watcher (≤ 10 s). El watcher extrae
el tarball y reinicia el servicio; no borra `.env` ni `data/`.

## Actualizaciones OTA

La app se actualiza desde el propio backend, sin Play Store:

1. `tools\publish-apk.ps1 -Notes "cambios"` compila el APK, escribe
   `dist/app/latest.json` (versión, `version_code`, sha256, tamaño y notas) y
   empuja APK + manifiesto al teléfono; el watcher los deja en
   `~/openterritorio/app/`.
2. El backend los sirve con token en `GET /api/app/latest` y
   `GET /api/app/download`.
3. La app compara su `versionCode` al arrancar (y con el botón de la barra),
   muestra las notas, descarga el APK verificando el **sha256** y lanza el
   instalador del sistema (`PackageInstaller`).

```powershell
# Sube la versión en app/pubspec.yaml (version: X.Y.Z+N) o pásala a mano:
powershell -ExecutionPolicy Bypass -File .\tools\publish-apk.ps1 `
  -Version 0.2.0 -BuildNumber 2 -Notes "tablero y ACK"
```

> **Firma**: para que Android acepte la actualización, todas las versiones deben
> estar firmadas con la **misma clave**. Sin `app/android/key.properties` se usa
> la debug key (sirve en el mismo PC, no entre runners de CI). En CI, define los
> secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
> `ANDROID_KEY_ALIAS` y `ANDROID_KEY_PASSWORD`; el workflow firma con ellos.
> En el teléfono hay que permitir "instalar apps desconocidas" para
> OPENTERITORIO la primera vez (la app abre ese ajuste si falta).

## Pruebas

```powershell
cd server
npm test
node tools/e2e.js --url https://tienda.tlalchichi.xyz --token <TOKEN>
node tools/sim.js --url wss://tienda.tlalchichi.xyz/ws --token <TOKEN> --peers 3 --duration 30
```

## Seguridad

- Token obligatorio en `/api/*` y `/ws` (incluida la descarga OTA del APK);
  `/healthz` es público a propósito.
- TLS lo termina Cloudflare; el origen no queda expuesto directamente.
- Límites: 200 clientes WS, frames ≤ 4 KB, 20 fallos de token/min por IP y
  **60 paquetes/s por cliente** (`WS_RATE_MAX` / `WS_RATE_WINDOW_MS`); quien
  inunda el socket se cierra con 1008.
- Retención en el teléfono: `SEEN_TTL_MS` (24 h), `TRACK_TTL_MS` (7 días),
  `EVENT_TTL_MS` (30 días, cubre eventos, alertas y ACK) y `PEER_TTL_MS`
  (7 días). El log rota solo a los `LOG_MAX_BYTES` (2 MB, una generación).
- `TRUST_CF_HEADER=0` ignora `cf-connecting-ip` cuando se entra por LAN, donde
  esa cabecera se puede falsear para esquivar el límite de fallos de token.
- El token no se versiona: vive en `~/openterritorio/.env` y en `backup/token.txt`.

## Fase B · app Flutter (completa)

`app/` contiene el cliente táctico: protocolo Protobuf implementado a mano,
WebSocket con reconexión exponencial, REST `/api/state`, tablero `CustomPainter`,
GPS real (`geolocator`), eventos desde el campo, ACK de alertas y ajustes
persistentes (`shared_preferences`).

### Mapa offline (todo el estado de Colima)

El tablero lleva una **pirámide de teselas** dentro del APK (sin red):

| Nivel | Cobertura | Uso |
| --- | --- | --- |
| z10–z13 | Estado completo (costa, volcán, 10 municipios, ~130 × 95 km) | contexto y zoom amplio |
| z14 | Estado completo con calles de cabeceras | uso normal |
| z15–z16 | Parches de detalle urbano: Colima, Villa de Álvarez, Manzanillo, Tecomán, Comala y Armería | calle a calle en las ciudades |

Son ~6 070 teselas JPEG (`app/assets/tiles/colima_<z>_<x>_<y>.jpg`, ~36 MB) que se
cargan bajo demanda con una caché LRU de 96 teselas (~25 MB de RAM), así que el
tamaño del mapa no crece en memoria: solo se decodifica lo visible. Si una
tesela aún no está cargada se dibuja el nivel inferior como respaldo y se
solicita la definitiva.

Se dibujan con proyección **Web Mercator** (la misma de las teselas) y encima van
las etiquetas propias (COLIMA, VILLA DE ÁLVAREZ, MANZANILLO, TECOMÁN, ARMERÍA,
COMALA, VOLCÁN DE COLIMA), la escala en m/km y la atribución
*© Esri, HERE, Garmin, © OpenStreetMap*.

Para regenerarlo o ampliar la cobertura: `python tools/fetch-tiles.py`
(fuente Esri Dark Gray Canvas, sin clave; añade niveles o parches editando
`STATE`, `PATCHES` y `STATE_LEVELS`).

`app/test/board_render_test.dart` pinta el tablero a PNG con teselas reales
(Colima y Manzanillo) y falla si más del 50 % del lienzo sigue siendo el color
de fondo: un mapa invisible no puede pasar.

> Requiere **Android 14 (API 34) o superior** (`minSdk = 34`, `targetSdk = 36`).
> La capa nativa usa directamente las APIs obligatorias en esa versión
> (`PackageInstaller`, `MediaStore.Downloads`, `FLAG_MUTABLE`).

> La capa `lib/data/` (estado + cliente del backend) se había quedado fuera del
> repositorio: la regla `data/` del `.gitignore` también excluía `app/lib/data/`.
> Ya está restaurada y cubierta por pruebas.

Verificado con Flutter 3.50.1 / JDK 17 / Android SDK 36 / Gradle 9.5:

| Comprobación | Resultado |
| --- | --- |
| `flutter analyze` | sin incidencias |
| `flutter test` | **26/26** (protocolo, estado, ajustes, texto, WebSocket/REST reales, OTA y render del mapa con teselas) |
| `flutter build apk --release` (universal) | **OK** |

Instrucciones en [`app/README.md`](app/README.md).

## Documentación

- [Estado del teléfono](docs/00-estado-celular.md)
- [Arquitectura y decisiones](docs/01-arquitectura.md)
- [Protocolo y API](docs/02-protocolo.md)
- [Runbook](docs/03-runbook.md)
- [Pruebas y aceptación](docs/04-pruebas.md)
