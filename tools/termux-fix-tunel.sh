#!/data/data/com.termux/files/usr/bin/sh
# Reintenta el túnel sin los --edge fijos (puerto 7844), que la red nueva puede
# estar bloqueando. Guarda el run original y deja el log en /sdcard/Download.
SVDIR=/data/data/com.termux/files/usr/var/service
HOME_DIR=/data/data/com.termux/files/home
OUT=/sdcard/Download/tunel.txt
LOG=/sdcard/Download/cf.log

{
  echo "== respaldo del run =="
  cp "$SVDIR/cloudflared/run" /sdcard/Download/cloudflared-run.bak && echo "ok"
} > "$OUT" 2>&1

cat > "$SVDIR/cloudflared/run" <<'FIN'
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH=$PREFIX/bin:/system/bin:/system/xbin
exec "$HOME/bin/cloudflared-edge" \
  --config "$HOME/.cloudflared/config.yml" \
  --loglevel info \
  tunnel run 55a19ff5-fe1e-489c-8eb4-f93a37af90d1 >> /sdcard/Download/cf.log 2>&1
FIN
chmod +x "$SVDIR/cloudflared/run"
echo "run reescrito sin --edge" >> "$OUT"

sv restart cloudflared >> "$OUT" 2>&1
sleep 30

{
  echo "== sv status =="; sv status cloudflared 2>&1
  echo "== prueba desde el telefono =="
  curl -s -o /dev/null -w "http a tienda.tlalchichi.xyz: %{http_code}\n" -m 15 https://tienda.tlalchichi.xyz/healthz 2>&1
  echo "== cola de cf.log =="; tail -n 30 "$LOG" 2>&1
} >> "$OUT" 2>&1
echo "fin" >> "$OUT"
