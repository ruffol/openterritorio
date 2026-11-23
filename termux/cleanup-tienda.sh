#!/data/data/com.termux/files/usr/bin/bash
# Reemplaza la tienda (tienda-dev) por OPENTERITORIO.
# 1) respalda ~/tienda-dev  2) detiene/elimina sus servicios y archivos
# 3) mueve el backend a :3000 (mismo origen que el túnel Cloudflare)
# 4) conserva cloudflared, ~/.cloudflared, sshd y Termux:Boot.
set -uo pipefail

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export SVDIR="$PREFIX/var/service"

LOG="/sdcard/Download/opcleanup.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/sdcard/Download/backup-tienda-$TS.tar.gz"
BACKUP_SD="/sdcard/Download/backup-tienda-sdcard-$TS.tar.gz"
echo "=== cleanup tienda $TS ==="

if [ -d "$HOME/tienda-dev" ]; then
  if ! tar -czf "$BACKUP" -C "$HOME" \
      --exclude='tienda-dev/node_modules' \
      --exclude='tienda-dev/.git' \
      tienda-dev; then
    echo "ERROR: no se pudo respaldar tienda-dev; abortando"
    exit 1
  fi
  echo "backup home: $BACKUP ($(du -h "$BACKUP" | cut -f1))"
else
  echo "aviso: ~/tienda-dev no existe"
fi

if [ -d /sdcard/tienda-dev ]; then
  if ! tar -czf "$BACKUP_SD" -C /sdcard tienda-dev; then
    echo "ERROR: no se pudo respaldar /sdcard/tienda-dev; abortando"
    exit 1
  fi
  echo "backup sdcard: $BACKUP_SD ($(du -h "$BACKUP_SD" | cut -f1))"
fi

for svc in tienda actualizador web-actualizador; do
  sv down "$svc" 2>/dev/null || true
  rm -rf "$SVDIR/$svc"
done
pkill -f "node index.js" 2>/dev/null || true
sleep 1

rm -rf "$HOME/tienda-dev" /sdcard/tienda-dev
echo "tienda eliminada del telefono (respaldo en $BACKUP)"

cd "$HOME/openterritorio" || exit 1
sed -i 's/^PORT=.*/PORT=3000/' .env
echo 3000 > /sdcard/Download/openterritorio.port
sv restart openterritorio 2>/dev/null || sv up openterritorio 2>/dev/null || true

ok=0
for _ in $(seq 1 40); do
  if node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done

if [ "$ok" != "1" ]; then
  echo "ERROR: el backend no responde en :3000"
  tail -n 30 "$PREFIX/var/log/openterritorio/current" 2>/dev/null
  exit 1
fi

echo "OK: backend en :3000"
sv status openterritorio cloudflared 2>&1
echo "backup_path=$BACKUP" > /sdcard/Download/opcleanup.done
echo "=== cleanup terminado ==="
