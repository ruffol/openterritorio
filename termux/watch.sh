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


# Comprueba que el backend responda; si no, restaura src.bak y reinicia.
salud() {
  for _ in $(seq 1 12); do
    sleep 2
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 2 "http://127.0.0.1:${PORT:-3000}/healthz" >/dev/null 2>&1 && return 0
    else
      wget -q -O /dev/null -T 2 "http://127.0.0.1:${PORT:-3000}/healthz" 2>/dev/null && return 0
    fi
  done
  return 1
}

# Copia a runit los servicios que traiga el despliegue (p. ej. el monitor de
# notas) y los levanta la primera vez.
instalar_servicios() {
  [ -d "$APP/termux/service" ] || return 0
  for dir in "$APP"/termux/service/*; do
    [ -d "$dir" ] || continue
    nombre=$(basename "$dir")
    destino="$SVDIR/$nombre"
    [ -d "$destino" ] && continue
    mkdir -p "$destino"
    cp "$dir/run" "$destino/run" 2>/dev/null || continue
    chmod +x "$destino/run"
    ln -sfn "$destino" "$SVDIR/../service/$nombre" 2>/dev/null || true
    sv up "$nombre" >>"$LOG" 2>&1 || true
    echo "$(date -Is) servicio $nombre instalado" >>"$LOG"
  done
}

reiniciar_backend() {
  sv restart openterritorio >>"$LOG" 2>&1 || sv up openterritorio >>"$LOG" 2>&1
  if salud; then
    echo "$(date -Is) servicio arriba" >>"$LOG"
    return 0
  fi
  echo "$(date -Is) ERROR: el backend no responde, restaurando src.bak" >>"$LOG"
  if [ -d "$APP/app/src.bak" ]; then
    rm -rf "$APP/app/src"
    mv "$APP/app/src.bak" "$APP/app/src"
    sv restart openterritorio >>"$LOG" 2>&1 || true
    if salud; then
      echo "$(date -Is) respaldo restaurado y servicio arriba" >>"$LOG"
    else
      echo "$(date -Is) ERROR: el respaldo tampoco arranca" >>"$LOG"
    fi
  else
    echo "$(date -Is) sin respaldo disponible" >>"$LOG"
  fi
  return 1
}

while true; do
  # Backend: extrae el tarball y reinicia el servicio.
  if [ -f "$STAMP" ] && [ -f "$TARBALL" ]; then
    NEW=$(cat "$STAMP" 2>/dev/null || true)
    OLD=$(cat "$APPLIED" 2>/dev/null || true)
    if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then
      echo "$(date -Is) deploy $NEW" >>"$LOG"
      if tar -xzf "$TARBALL" -C "$APP" >>"$LOG" 2>&1; then
        echo "$NEW" >"$APPLIED"
        instalar_servicios
        reiniciar_backend || true
        # Si este deploy trae un watch.sh nuevo, recárgalo con runit.
        sv restart openterritorio-deploy >>"$LOG" 2>&1 || true
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
