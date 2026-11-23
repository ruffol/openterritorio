# 01 · Arquitectura y decisiones

## La idea original (PDF)

`docs/especificacion.pdf` define una app Android **offline-first** con:

- Mapas vectoriales/satelitales locales (PMTiles/MBTiles, MapLibre, Flutter).
- Rastreo GPS en primer plano y en segundo plano (Foreground Service).
- Eventos georreferenciados y alertas del servidor.
- Transporte desacoplado: WebSocket, BLE (LoRa/Meshtastic), USB serial, malla
  Nearby Connections y audio AFSK.
- Paquetes **Protobuf** de ~25–45 bytes, idempotencia y deduplicación.
- Backend central Node/Go + Redis + PostgreSQL/PostGIS + FCM.

## Qué se construyó en esta fase

El **backend** corriendo en el teléfono, con el mismo contrato binario y una API
HTTP para el panel. La app Flutter, los adaptadores BLE/USB/malla/AFSK y el
pipeline de teselas son fases posteriores.

```
            Internet
               │  HTTPS / WSS (Cloudflare)
               ▼
     tienda.tlalchichi.xyz
               │  túnel cloudflared (existente)
               ▼
  ┌───────────────────────────────┐
  │ Teléfono Q524 · Termux        │
  │                               │
  │  node app/src/server.js :3000 │
  │   ├─ HTTP (Express)           │
  │   │   ├─ /healthz             │
  │   │   ├─ /api/*  (token)      │
  │   │   └─ panel estático       │
  │   ├─ WebSocket /ws (token)    │
  │   ├─ Ingesta + dedup          │
  │   ├─ Repositorio SQLite       │
  │   └─ Hub de broadcast         │
  │                               │
  │  runit: openterritorio        │
  │         openterritorio-deploy │
  └───────────────────────────────┘
```

## Decisiones

| Tema | PDF (servidor central) | Teléfono (esta fase) | Motivo |
| --- | --- | --- | --- |
| Runtime | Node/Go | **Node.js 24** | ya instalado y probado en el teléfono |
| Persistencia | PostgreSQL/PostGIS | **SQLite (`node:sqlite`)** | 2 GB RAM, sin compilar módulos nativos |
| Tiempo real | Redis Pub/Sub | **EventEmitter + hub en proceso** | una sola instancia |
| Mensajería | Protobuf | **Protobuf (igual)** | contrato compatible |
| Push | FCM | **no** | sin credenciales; se difiere |
| TLS | balanceador | **Cloudflare Tunnel** | ya existía y evita abrir puertos |
| Despliegue | contenedores | **runit + tarball + watcher** | Termux, sin Docker |
| Autenticación | cuentas | **token Bearer** | MVP operativo en LAN/público |

Todo el estado vive en `~/openterritorio/data/tactical.db` (WAL). El contrato
(`proto/tactical_packet.proto`) es idéntico al del PDF salvo la extensión
`AckPayload` (campo 9) para confirmaciones dirigidas.

## Componentes

- `server/src/hub.js` — WebSocket sobre el mismo puerto; autentica en el
  handshake, solo frames binarios, ping/pong cada 30 s, descarte de lentos.
- `server/src/ingest.js` — decodifica, valida, deduplica por `packet_id`,
  persiste y difunde (excepto ACK y excepto al emisor).
- `server/src/db.js` — esquema y consultas; retención de 24 h para dedup y 7
  días para tracks.
- `server/src/rest.js` — REST + panel; `/api/*` exige token.
- `server/public/` — panel HTML/JS sin dependencias externas.
- `termux/watch.sh` — aplica `openterritorio.tar.gz` cuando cambia el stamp
  subido por adb; reinicia el servicio en ≤ 10 s.

## Modelo de datos

| Tabla | Contenido |
| --- | --- |
| `peers` | última posición conocida por `sender_id` |
| `tracks` | historial de posiciones (7 días) |
| `events` | eventos georreferenciados (`packet_id` único) |
| `alerts` | alertas del servidor/panel (`packet_id` único) |
| `acks` | confirmaciones por alerta y dispositivo |
| `packets_seen` | deduplicación (24 h) |

## Capacidad esperada

- 200 conexiones WS configuradas; el hardware realista aguanta decenas con
  paquetes de ~50 bytes.
- Node ocupa ~50–80 MB RSS; quedan ~1,3 GB disponibles.
- El cuello es la CPU Cortex-A7 y el Wi-Fi; el túnel añade ~100 ms.

## Siguiente fase (propuesta)

1. **App Flutter** (Fase 1 del PDF): MapLibre + MBTiles/PMTiles, GPS en primer
   plano, SQLite/Drift y `WebSocketAdapter` contra este backend.
2. **Foreground Service** y cola de sincronización (Fase 3).
3. **BLE/USB** (Fase 4) y **malla/AFSK** (Fase 5).
4. Si hace falta servidor central, reutilizar el mismo `proto` y la misma API;
   SQLite se sustituye por PostGIS sin tocar el contrato.
