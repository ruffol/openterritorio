# 02 · Protocolo y API

## Paquete binario

Fuente: `proto/tactical_packet.proto`. Compartido por todos los transportes.

### `TacticalPacket`

| Campo | N.º | Tipo | Notas |
| --- | --- | --- | --- |
| `packet_id` | 1 | bytes | **8 bytes**; deduplicación |
| `sender_id` | 2 | uint32 | 0 = servidor/panel |
| `timestamp` | 3 | uint64 | epoch en segundos |
| `hop_limit` | 4 | uint32 | mesh; el backend no lo decrementa |
| `type` | 5 | enum | ver abajo |
| `position` | 6 | PositionPayload | oneof |
| `event` | 7 | EventPayload | oneof |
| `alert` | 8 | AlertPayload | oneof |
| `ack` | 9 | AckPayload | **extensión local** |

`PacketType`: `POSITION_UPDATE=0`, `USER_EVENT=1`, `SERVER_ALERT=2`,
`ACK_CONFIRMATION=3`.

### Cargas

- **PositionPayload**: `latitude_e7` (sint32), `longitude_e7` (sint32),
  `altitude_m` (int32), `speed_cms` (uint32), `heading_deg` (0–359),
  `battery_pct` (0–100).
- **EventPayload**: `category_id`, `latitude_e7`, `longitude_e7`,
  `short_note` (≤ 64 bytes UTF-8).
- **AlertPayload**: `severity` (1–3), `latitude_e7`, `longitude_e7`,
  `radius_m`, `title` (≤ 64 bytes).
- **AckPayload**: `acked_packet_id` (8 bytes).

Tamaño real de un `POSITION_UPDATE` completo: **46–48 bytes** (cabe en LoRa).

## WebSocket

```
ws(s)://HOST/ws?token=TOKEN[&transport=ws|ble|usb|mesh|afsk]
```

- Solo frames **binarios** (`TacticalPacket`); un frame de texto cierra con 1003.
- Handshake sin token válido → HTTP **401**.
- Heartbeat: `ping` cada 30 s; sin `pong` se termina la conexión.
- `maxPayload` 4 KB; clientes lentos (>512 KB en cola) se saltan.
- `transport` es informativo (se guarda en `peers.transport`).

## REST

Todas las rutas `/api/*` requieren `Authorization: Bearer TOKEN` (o
`?token=TOKEN`). `/healthz` y el panel estático son públicos.

| Método | Ruta | Descripción |
| --- | --- | --- |
| GET | `/healthz` | `{ok, ts}` público |
| GET | `/api/health` | uptime, versión, tamaño DB, contadores, clientes WS |
| GET | `/api/state` | snapshot: peers, eventos (200), alertas (50), contadores |
| GET | `/api/peers` | últimas posiciones |
| GET | `/api/events?limit=` | eventos recientes |
| POST | `/api/events` | crea evento `sender_id=0` y lo difunde |
| GET | `/api/alerts?limit=` | alertas + `ack_count` |
| POST | `/api/alerts` | crea alerta y la difunde |
| GET | `/api/alerts/:packetId/acks` | acks de una alerta (hex de 16) |
| GET | `/api/tracks/:senderId?since_ms=&limit=` | historial (máx. 20 000) |
| POST | `/api/packets` | cuerpo `application/x-protobuf` (fallback HTTP) |
| GET | `/api/logs?lines=` | últimas líneas del log JSON |

Cuerpos JSON de ejemplo:

```json
{ "severity": 3, "lat": 19.2433, "lon": -103.7247, "radius_m": 500, "title": "Zona de riesgo" }
{ "category_id": 4, "lat": 19.2433, "lon": -103.7247, "short_note": "Punto de reunión" }
```

## Semántica de ingesta

1. Decodificar y validar (rangos, tamaños, severidad, tipo ↔ payload).
2. `INSERT OR IGNORE` en `packets_seen`; si ya existía → **duplicado**, no se
   reenvía (pero no es error).
3. Persistir según tipo (peer + track / evento / alerta / ack).
4. Difundir a todos menos al emisor (ACK no se difunde).
5. El cliente que recibe una alerta responde `ACK_CONFIRMATION` con el
   `packet_id` de la alerta.

## Errores

```json
{ "ok": false, "error": "unauthorized" }
```

- 400 validación, 401 token, 404 ruta, 415 cuerpo no protobuf, 500 interno.
- Cierre WS: 1003 (texto), 1009 (payload), 1013 (saturado).

## Cliente mínimo (Node)

```js
const WebSocket = require('ws');
const proto = require('./server/src/proto');
const ws = new WebSocket('wss://tienda.tlalchichi.xyz/ws?token=' + TOKEN);
ws.on('open', () => ws.send(proto.encode({
  packet_id: require('crypto').randomBytes(8),
  sender_id: 7, timestamp: Math.floor(Date.now() / 1000), hop_limit: 3, type: 0,
  position: { latitude_e7: 192433000, longitude_e7: -1037247000, battery_pct: 90 },
})));
```

Utilidades listas: `server/tools/sim.js` (simulador) y `server/tools/e2e.js`
(prueba de humo).
