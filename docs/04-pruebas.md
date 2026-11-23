# 04 · Pruebas y aceptación

Fecha: **2026-11-23** (America/Mexico_City).

## Resultados

| Prueba | Ámbito | Resultado |
| --- | --- | --- |
| `npm test` (14 casos) | PC | **14/14** |
| e2e LAN `http://192.168.100.3:8080` | teléfono | **10/10** |
| e2e público `https://tienda.tlalchichi.xyz` | teléfono + Cloudflare | **10/10** |
| Hot deploy (stamp → watcher → restart) | teléfono | OK; datos persistieron |
| Panel y `/api/state` | LAN | OK (peers/events/alerts) |
| Tienda retirada; `cloudflared` intacto | teléfono | OK |

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

## Pendientes (no bloqueantes)

- **Reinicio real del teléfono** para validar Termux:Boot de punta a punta (el
  runsvdir existente ya arranca todos los servicios; falta la prueba física).
- Prueba de carga con 20–50 clientes y medición de RSS/CPU.
- Pruebas desde la app Flutter (fase siguiente) y desde transporte BLE/USB.
