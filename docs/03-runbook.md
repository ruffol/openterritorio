# 03 · Runbook

## Datos de acceso

| Dato | Valor |
| --- | --- |
| Panel | <https://tienda.tlalchichi.xyz> |
| API | `https://tienda.tlalchichi.xyz/api/…` (Bearer) |
| WebSocket | `wss://tienda.tlalchichi.xyz/ws?token=…` |
| LAN | `http://192.168.100.3:3000` |
| Token | `backup/token.txt` (PC) y `~/openterritorio/.env` (teléfono) |
| Logs | `$PREFIX/var/log/openterritorio/current` y `~/openterritorio/logs/` |
| DB | `~/openterritorio/data/tactical.db` |

## Desplegar cambios

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -Port 3000
```

Hace: tests → arma `dist/openterritorio.tar.gz` (código + `node_modules` puro
JS) → `adb push` del tarball y del stamp → el servicio `openterritorio-deploy`
extrae y reinicia en ≤ 10 s → comprueba `/healthz`.

Sin prisa por el watcher: `-SkipTests` y/o `-NoPush` para solo empaquetar.

Despliegue manual del stamp (forzar reaplicación):

```powershell
adb shell "echo manual-$(Get-Date -Format s) > /sdcard/Download/openterritorio.stamp"
```

## Control remoto por SSH

`sshd` escucha en **8022** con autenticación solo por clave (sin contraseña).
Usuario `u0_a187`; clave `backup/phone_ed25519` (no versionada).

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\ssh.ps1 -Command "sv status openterritorio"

# equivalente
ssh -p 8022 -i .\backup\phone_ed25519 -o StrictHostKeyChecking=no u0_a187@192.168.100.3 "comando"
```

Si el teléfono no está en la LAN: `adb forward tcp:8022 tcp:8022` y conectar a
`127.0.0.1`. `sshd` está habilitado en boot (`sv-enable sshd`).

## Estado y pruebas

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\health.ps1 -Port 3000 -Public
cd server
node tools/e2e.js --url https://tienda.tlalchichi.xyz --token <TOKEN>
node tools/sim.js --url wss://tienda.tlalchichi.xyz/ws --token <TOKEN> --peers 3 --duration 20
```

Reiniciar el servicio desde Termux (o con `tools\termux-type.ps1 -Command "sv restart openterritorio"`):

```bash
sv restart openterritorio
sv status openterritorio openterritorio-deploy cloudflared
```

## Ver logs

```powershell
# desde el panel/API
Invoke-WebRequest "http://192.168.100.3:3000/api/logs?lines=100" -Headers @{Authorization="Bearer <TOKEN>"}
```

```bash
# en Termux
tail -n 80 "$PREFIX/var/log/openterritorio/current"
tail -n 40 ~/openterritorio/logs/deploy.log
tail -n 40 ~/openterritorio/logs/server.log
```

## Rotar el token

1. En Termux: `cd ~/openterritorio && sed -i '/^TOKEN=/d' .env`
2. `PORT=3000 bash termux/install.sh` (genera token nuevo y reinicia).
3. Copiar el nuevo token desde `/sdcard/Download/openterritorio.token` al PC y
   actualizar `backup/token.txt` y los clientes.

## Respaldo de la base

```bash
cd ~/openterritorio
node -e "const{DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('data/tactical.db');d.exec('PRAGMA wal_checkpoint(TRUNCATE)');d.close()"
cp data/tactical.db /sdcard/Download/tactical-$(date +%Y%m%d-%H%M).db
```

Luego `adb pull /sdcard/Download/tactical-*.db backup/`.

Para dejar la base vacía (por ejemplo tras una demo):

```bash
bash ~/openterritorio/termux/reset-db.sh
```

## Restaurar la tienda anterior

Los respaldos están en `backup/` del PC. La tienda usaba `:3000`; hay que
liberar el puerto o mover el backend.

1. Detener OPENTERITORIO: `sv down openterritorio`.
2. `adb push backup\backup-tienda-20261123-103410.tar.gz /sdcard/Download/`
3. En Termux:
   ```bash
   tar -xzf /sdcard/Download/backup-tienda-20261123-103410.tar.gz -C "$HOME"
   cd "$HOME/tienda-dev" && npm install --omit=dev
   ```
4. Recrear el servicio `tienda` (mismo patrón que `install.sh`):
   ```bash
   mkdir -p "$PREFIX/var/service/tienda"
   cat > "$PREFIX/var/service/tienda/run" <<'EOF'
   #!/data/data/com.termux/files/usr/bin/sh
   export PREFIX=/data/data/com.termux/files/usr
   export HOME=/data/data/com.termux/files/home
   export PATH=$PREFIX/bin:/system/bin:/system/xbin
   cd "$HOME/tienda-dev" || exit 1
   exec node index.js
   EOF
   chmod +x "$PREFIX/var/service/tienda/run"
   sv up tienda
   ```
5. El túnel ya apunta a `localhost:3000`; la URL vuelve a servir la tienda.

## Retirar OPENTERITORIO

```bash
bash ~/openterritorio/termux/uninstall.sh
```

Detiene y borra los servicios `openterritorio*` y `~/openterritorio`. **No toca**
`cloudflared` ni Termux:Boot.

## Arranque tras reiniciar el teléfono

- `~/.termux/boot/start-services.sh` (Termux:Boot, ya existente) lanza
  `runsvdir`, que inicia `openterritorio`, `openterritorio-deploy` y
  `cloudflared`.
- Termux:Boot debe haberse abierto una vez (ya está instalado).
- Si tras un reinicio no hay servicio: abrir Termux una vez; su `.bashrc`
  levanta el supervisor. Comprobar con `sv status`.
- El teléfono debe estar desbloqueado o sin PIN que impida el arranque de apps
  no direct-boot.

## Problemas comunes

| Síntoma | Causa / solución |
| --- | --- |
| Cloudflare devuelve 502 | Node caído: `sv status openterritorio`, logs en `var/log`. |
| 401 en panel/API | Token incorrecto o rotado; volver a introducirlo. |
| `EADDRINUSE :3000` | Otro proceso en 3000 (¿tienda restaurada?); `pkill -f "node index.js"` o mover puerto. |
| El watcher no aplica | Falta `/sdcard/Download/openterritorio.tar.gz` o el stamp no cambió. |
| El teléfono no responde en LAN | Wi-Fi dormido, IP cambiada o AP aislado; revisar `ip -4 addr show wlan0`. |
| `adb devices` vacío | Re-enumerar el dispositivo USB compuesto (o reconectar el cable). |
| Latencia alta | CPU Cortex-A7 + Wi-Fi; normal ~100 ms desde el PC. |
