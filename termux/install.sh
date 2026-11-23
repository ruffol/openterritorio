#!/data/data/com.termux/files/usr/bin/bash
# Instala/actualiza el servicio openterritorio en Termux (runit).
# Uso: [PORT=3000] bash install.sh
set -uo pipefail

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export SVDIR="$PREFIX/var/service"

APP="$HOME/openterritorio"
PORT="${PORT:-3000}"
LOG="/sdcard/Download/opinstall.log"
mkdir -p /sdcard/Download

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

cd "$APP" || { log "ERROR: no existe $APP"; exit 1; }
mkdir -p data logs
chmod +x termux/*.sh 2>/dev/null || true

if ! command -v node >/dev/null 2>&1; then
  log "node no encontrado; instalando nodejs-lts..."
  pkg install -y nodejs-lts >>"$LOG" 2>&1 || { log "ERROR instalando node"; exit 1; }
fi
log "node $(node --version)"

NODEFLAGS=""
if node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  log "node:sqlite disponible sin flags"
elif node --experimental-sqlite -e 'require("node:sqlite")' >/dev/null 2>&1; then
  NODEFLAGS="--experimental-sqlite"
  log "node:sqlite con flag --experimental-sqlite"
else
  log "ERROR: este Node no trae node:sqlite (se requiere >= 22.5)"
  exit 1
fi

if [ ! -f .env ]; then
  TOKEN=$(node -e 'console.log(require("node:crypto").randomBytes(24).toString("hex"))')
  cat > .env <<EOF
PORT=$PORT
HOST=0.0.0.0
DB_PATH=data/tactical.db
LOG_FILE=logs/server.log
TOKEN=$TOKEN
PUBLIC_URL=https://tienda.tlalchichi.xyz
EOF
  chmod 600 .env
  log "token generado"
else
  log ".env existente conservado (puerto $(grep '^PORT=' .env | cut -d= -f2-))"
fi

if ! pgrep -f runsvdir >/dev/null 2>&1; then
  log "runsvdir no activo; iniciándolo"
  nohup "$PREFIX/bin/runsvdir" "$SVDIR" >>"$HOME/runsvdir.log" 2>&1 &
  sleep 2
fi

mkdir -p "$SVDIR/openterritorio/log" "$PREFIX/var/log/openterritorio"
cat > "$SVDIR/openterritorio/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
export PREFIX=$PREFIX
export HOME=$HOME
export PATH=$PREFIX/bin:/system/bin:/system/xbin
export SVDIR=$SVDIR
cd $APP || exit 1
exec node $NODEFLAGS app/src/server.js
EOF
cat > "$SVDIR/openterritorio/log/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt $PREFIX/var/log/openterritorio
EOF
chmod +x "$SVDIR/openterritorio/run" "$SVDIR/openterritorio/log/run"

mkdir -p "$SVDIR/openterritorio-deploy"
cat > "$SVDIR/openterritorio-deploy/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
export PREFIX=$PREFIX
export HOME=$HOME
export PATH=$PREFIX/bin:/system/bin:/system/xbin
export SVDIR=$SVDIR
exec bash $APP/termux/watch.sh
EOF
chmod +x "$SVDIR/openterritorio-deploy/run"

sv up openterritorio >>"$LOG" 2>&1 || true
sv up openterritorio-deploy >>"$LOG" 2>&1 || true

ok=0
for _ in $(seq 1 40); do
  if node -e "fetch('http://127.0.0.1:$PORT/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done

if [ "$ok" != "1" ]; then
  log "ERROR: el backend no respondió en 127.0.0.1:$PORT"
  tail -n 25 "$PREFIX/var/log/openterritorio/current" 2>/dev/null
  tail -n 25 logs/server.log 2>/dev/null
  exit 1
fi

TOKEN=$(grep '^TOKEN=' .env | cut -d= -f2-)
echo "$TOKEN" > /sdcard/Download/openterritorio.token
echo "$PORT" > /sdcard/Download/openterritorio.port

IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
log "OK puerto $PORT · token escrito en /sdcard/Download/openterritorio.token"
log "LAN: http://${IP:-IP}:$PORT  ·  WS: ws://${IP:-IP}:$PORT/ws"
sv status openterritorio 2>&1 | tee -a "$LOG"
