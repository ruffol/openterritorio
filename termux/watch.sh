#!/data/data/com.termux/files/usr/bin/bash
# Vigila los stamps de /sdcard/Download:
#   openterritorio.stamp          -> aplica el tarball del backend
#   openterritorio-app/app.stamp  -> publica el APK para OTA
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
APK_DIR="/sdcard/Download/openterritorio-app"
APK_STAMP="$APK_DIR/app.stamp"
APK_APPLIED="$APP/.apk_stamp"
LOG="$APP/logs/deploy.log"
mkdir -p "$APP/logs"

while true; do
  # Backend: extrae el tarball y reinicia el servicio.
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

  # OTA: el backend sirve ~/openterritorio/app/latest.json y el APK.
  if [ -f "$APK_STAMP" ] && [ -f "$APK_DIR/openterritorio.apk" ] && [ -f "$APK_DIR/latest.json" ]; then
    NEW_APK=$(cat "$APK_STAMP" 2>/dev/null || true)
    OLD_APK=$(cat "$APK_APPLIED" 2>/dev/null || true)
    if [ -n "$NEW_APK" ] && [ "$NEW_APK" != "$OLD_APK" ]; then
      mkdir -p "$APP/app"
      if cp "$APK_DIR/openterritorio.apk" "$APP/app/openterritorio.apk" &&
        cp "$APK_DIR/latest.json" "$APP/app/latest.json"; then
        chmod 644 "$APP/app/openterritorio.apk" "$APP/app/latest.json" 2>/dev/null || true
        echo "$NEW_APK" >"$APK_APPLIED"
        echo "$(date -Is) APK OTA publicado $NEW_APK" >>"$LOG"
      else
        echo "$(date -Is) ERROR al copiar el APK OTA" >>"$LOG"
      fi
    fi
  fi

  sleep 10
done
