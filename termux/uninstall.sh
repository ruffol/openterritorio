#!/data/data/com.termux/files/usr/bin/bash
# Retira los servicios openterritorio y los archivos de la app.
# No toca cloudflared ni Termux:Boot.
set -uo pipefail

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export SVDIR="$PREFIX/var/service"

sv down openterritorio openterritorio-deploy 2>/dev/null || true
rm -rf "$SVDIR/openterritorio" "$SVDIR/openterritorio-deploy"
rm -rf "$HOME/openterritorio"

echo "openterritorio retirado. cloudflared sigue intacto."
sv status cloudflared 2>/dev/null || true
