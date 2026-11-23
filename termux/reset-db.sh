#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export SVDIR="$PREFIX/var/service"

cd "$HOME/openterritorio" || exit 1
sv down openterritorio 2>/dev/null || true
rm -f data/tactical.db data/tactical.db-wal data/tactical.db-shm
sv up openterritorio 2>/dev/null || true
for _ in $(seq 1 30); do
  if node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
echo "db reset $(date)" > /sdcard/Download/opreset.done
echo "ok"
