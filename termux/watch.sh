#!/data/data/com.termux/files/usr/bin/bash
# Vigila /sdcard/Download/openterritorio.stamp y aplica el tarball nuevo.
# Se ejecuta como servicio runit "openterritorio-deploy".
set -uo pipefail

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export SVDIR="$PREFIX/var/service"

APP="$HOME/openterritorio"
STAMP="/sdcard/Download/openterritorio.stamp"
TARBALL="/sdcard/Download/openterritorio.tar.gz"
APPLIED="$APP/.deployed_stamp"
LOG="$APP/logs/deploy.log"
mkdir -p "$APP/logs"

while true; do
  if [ -f "$STAMP" ] && [ -f "$TARBALL" ]; then
    NEW=$(cat "$STAMP" 2>/dev/null || true)
    OLD=$(cat "$APPLIED" 2>/dev/null || true)
    if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then
      echo "$(date -Is) deploy $NEW" >>"$LOG"
      if tar -xzf "$TARBALL" -C "$APP" >>"$LOG" 2>&1; then
        echo "$NEW" >"$APPLIED"
        sv restart openterritorio >>"$LOG" 2>&1 || sv up openterritorio >>"$LOG" 2>&1
        echo "$(date -Is) servicio reiniciado" >>"$LOG"
      else
        echo "$(date -Is) ERROR al extraer el tarball" >>"$LOG"
      fi
    fi
  fi
  sleep 10
done
