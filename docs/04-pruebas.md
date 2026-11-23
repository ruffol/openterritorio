# 04 · Pruebas y aceptación

Fecha: **2026-11-23** (America/Mexico_City).

## Resultados

| Prueba | Ámbito | Resultado |
| --- | --- | --- |
| `npm test` (16 casos) | PC | **16/16** |
| e2e LAN `http://192.168.100.3:8080` | teléfono | **10/10** |
| e2e público `https://tienda.tlalchichi.xyz` | teléfono + Cloudflare | **10/10** |
| Hot deploy (stamp → watcher → restart) | teléfono | OK; datos persistieron |
| Panel y `/api/state` | LAN y público | OK (pares/eventos/alertas) |
| Tienda retirada; `cloudflared` intacto | teléfono | OK |
| **Reinicio completo** | teléfono | `boot_completed` 30 s; URL pública a los **55 s**; datos intactos |
| **Carga 20 clientes WS** | público | **15 200/15 200** difusiones, RSS **55 MB**, CPU **29 %** |

Cobertura e2e: `healthz` público, 401 sin token, estado con token, dos clientes
WS, broadcast de posición, deduplicación, evento, alerta por REST, broadcast de
alerta y ACK registrado.

## Reproducir

```powershell
cd server
npm test
node tools/e2e.js --url http://192.168.100.3:3000 --token <TOKEN>
node tools/e2e.js --url https://tienda.tlalchichi.xyz --token <TOKEN>
node tools/sim.js --url wss://tienda.tlalchichi.xyz/ws --token <TOKEN> --peers 3 --duration 20
```

## Casos unitarios

- Round-trip de `POSITION_UPDATE` y `ACK_CONFIRMATION`.
- Serialización de bytes a hex para JSON.
- Rechazo de `packet_id` ≠ 8 bytes, payload incoherente y coordenadas fuera de
  rango.
- Tamaño realista (≤ 55 bytes, LoRa).

## Casos de integración

- Broadcast a otros clientes.
- Deduplicación (mismo paquete dos veces → un solo reenvío).
- Persistencia de eventos en SQLite.
- Alerta REST + broadcast + ACK consultable.
- Token inválido en WS (401) y REST (401).
- Persistencia tras reinicio del proceso (misma DB).
- `healthz` no filtra contadores.

## App Flutter

Verificado el **2026-11-23** con Flutter 3.50.1, Dart 3.14, JDK 17 y SDK 36:

| Prueba | Resultado |
| --- | --- |
| `flutter analyze` | sin incidencias |
| `flutter test` (14 casos) | **14/14** |
| `flutter build apk --release` (universal) | **OK** |

- Protocolo: codificación byte a byte contra vectores de `protobufjs` (posición,
  evento, alerta y ACK), decodificación de los paquetes del servidor y
  coordenadas negativas.
- Estado: pares/eventos/alertas, deduplicación por `packet_id`, filtrado del eco
  propio y carga de `/api/state`.
- Cliente: WebSocket y REST reales en loopback (token, frames binarios, 401).
- OTA: metadata, descarga autenticada, verificación de sha256 (y rechazo si no
  coincide), instalación inyectada y 404 sin publicación.
- Extremo a extremo con el backend Node:
  `dart run tool/wire_check.dart http://127.0.0.1:3999 <token>` → posición
  persistida, alerta recibida por WS, ACK registrado y APK de OTA descargado
  con sha256 verificado (`OK` en los cuatro pasos).

## Pendientes (no bloqueantes)

- Pruebas en un segundo teléfono real (no solo el Q524).
- Transporte BLE/USB/malla/AFSK y mapa vectorial (fases posteriores del PDF).
- Carga sostenida > 30 clientes y con paquetes de evento/alerta mezclados.
