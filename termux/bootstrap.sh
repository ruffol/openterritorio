#!/data/data/com.termux/files/usr/bin/bash
# Bootstrap único de OPENTERITORIO dentro de Termux.
# Requiere /sdcard/Download/openterritorio.tar.gz subido por adb.
# Uso: bash /sdcard/Download/opbootstrap.sh
set -uo pipefail

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:/system/bin:/system/xbin"

LOG="/sdcard/Download/opbootstrap.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== OPENTERITORIO bootstrap $(date) ==="

if [ ! -f /sdcard/Download/openterritorio.tar.gz ]; then
  echo "ERROR: falta /sdcard/Download/openterritorio.tar.gz"
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "Instalando tar..."
  pkg install -y tar >>"$LOG" 2>&1 || { echo "ERROR instalando tar"; exit 1; }
fi

mkdir -p "$HOME/openterritorio"
tar -xzf /sdcard/Download/openterritorio.tar.gz -C "$HOME/openterritorio" || {
  echo "ERROR extrayendo tarball"
  exit 1
}
chmod +x "$HOME/openterritorio/termux/"*.sh

# Habilitar RUN_COMMAND/plugins de Termux (queda para futuras automatizaciones).
mkdir -p "$HOME/.termux"
touch "$HOME/.termux/termux.properties"
if ! grep -q '^allow-external-apps=true' "$HOME/.termux/termux.properties" 2>/dev/null; then
  echo 'allow-external-apps=true' >>"$HOME/.termux/termux.properties"
fi

termux-wake-lock 2>/dev/null || true

PORT="${PORT:-8080}" bash "$HOME/openterritorio/termux/install.sh"
echo "=== bootstrap terminado $(date) ==="
