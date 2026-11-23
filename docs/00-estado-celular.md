# 00 · Estado del teléfono (servidor)

Inventario verificado por adb el **2026-11-23** (America/Mexico_City).

## Dispositivo

| Dato | Valor |
| --- | --- |
| Marca / modelo | FISE / QTOUCH **Q524** |
| Android | 14 (SDK 34), parche 2026-11-05 |
| SoC | Unisoc **SP7731E** (4× Cortex-A7) |
| ABI | **armeabi-v7a** únicamente (32 bits) |
| RAM | 2 GB (`ro.config.low_ram=true`) |
| Pantalla | 480×854, densidad 180 |
| Almacenamiento | 26 GB, ~20 GB libres |
| Root | **no** (`ro.secure=1`, bootloader bloqueado, sin `su`) |
| Batería | 84 %, enchufado por USB, ~36 °C |
| Red | Wi-Fi `192.168.100.3/24` (DHCP), internet OK |
| ADB | USB `VID_18D1`; el enlace se cae a veces y se recupera re-enumerando el dispositivo compuesto en Windows |

## Software ya instalado

- **Termux 0.118.3** (targetSdk 28), **Termux:Boot 0.8.1**, F-Droid.
- Node **v24.22.3** con `node:sqlite` nativo (sin flag).
- Permisos concedidos: almacenamiento, notificaciones, wake lock, boot.
- `com.termux` está en la lista blanca de batería (`dumpsys deviceidle whitelist`).
- `settings_enable_monitor_phantom_procs=false` (sin asesino de procesos fantasma).
- `termux-wake-lock` activo desde el script de arranque existente.

## Servicios runit (después del cambio)

| Servicio | Estado | Nota |
| --- | --- | --- |
| `openterritorio` | run | backend Node en `:3000` |
| `openterritorio-deploy` | run | watcher de despliegue (`watch.sh`) |
| `cloudflared` | run | túnel existente; **intacto** |
| `sshd`, `ssh-agent` | run | del setup anterior; se conservan |
| `respaldo` | down | servicio previo inactivo; no se tocó |
| ~~`tienda`~~ | eliminado | portal anterior retirado |
| ~~`actualizador`~~, ~~`web-actualizador`~~ | eliminados | ya no aplican |

`runsvdir` corre desde `~/.termux/boot/start-services.sh` (Termux:Boot) y
arranca todos los directorios de `$PREFIX/var/service`.

## Cloudflare

- El `cloudflared` existente (2022.10.3 con `--edge`) sigue apuntando a
  `http://localhost:3000`.
- Hostname público: **https://tienda.tlalchichi.xyz**.
- Al mover el backend a `:3000`, el mismo hostname pasó a servir el panel y la
  API sin tocar `~/.cloudflared/config.yml` ni el DNS.
- El túnel no se reinició.

## Qué se retiró (con respaldo)

- `~/tienda-dev` (código, `tienda.db`, WAL/SHM) → `backup/backup-tienda-20261123-103410.tar.gz`.
- `/sdcard/tienda-dev` (copia, logs, `ssh-key.txt`) → `backup/backup-tienda-sdcard-20261123-103410.tar.gz`.
- Servicios `tienda`, `actualizador`, `web-actualizador` y sus directorios.
- Las copias y el token temporal se borraron de `/sdcard` del teléfono; solo
  quedan en el PC (`backup/`).

## Riesgos del hardware

- 32 bits y 2 GB: techo práctico de decenas de clientes WS; el PDF asume un
  servidor central. Ver `docs/01-arquitectura.md`.
- Wi-Fi con latencia de ~100 ms y posibles ahorros de energía; el wake lock y la
  lista blanca mitigan, no eliminan, las pausas.
- El teléfono debe seguir enchufado y en la misma red; si cambia de IP, el
  túnel sigue funcionando (Cloudflare conecta a `localhost`).
