#!/data/data/com.termux/files/usr/bin/sh
# Túnel con IPs fijas del edge (sin depender del DNS de Go, que en Termux no
# funciona) y protocolo http2 explícito.
SVDIR=/data/data/com.termux/files/usr/var/service
OUT=/sdcard/Download/tunel2.txt
LOG=/sdcard/Download/cf2.log

: > "$LOG"
cat > "$SVDIR/cloudflared/run" <<'FIN'
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH=$PREFIX/bin:/system/bin:/system/xbin
exec "$HOME/bin/cloudflared-edge" \
  --edge 198.41.192.7:7844 \
  --edge 198.41.192.167:7844 \
  --edge 198.41.200.13:7844 \
  --edge 198.41.200.113:7844 \
  --protocol http2 \
  --config "$HOME/.cloudflared/config.yml" \
  --loglevel info \
  tunnel run 55a19ff5-fe1e-489c-8eb4-f93a37af90d1 >> /sdcard/Download/cf2.log 2>&1
FIN
chmod +x "$SVDIR/cloudflared/run"

sv restart cloudflared > "$OUT" 2>&1
sleep 35

{
  echo "== sv status =="; sv status cloudflared 2>&1
  echo "== prueba local =="; curl -s -o /dev/null -w "healthz local: %{http_code}\n" -m 10 http://127.0.0.1:3000/healthz 2>&1
  echo "== prueba publica desde el telefono =="; curl -s -o /dev/null -w "publico: %{http_code}\n" -m 15 https://tienda.tlalchichi.xyz/healthz 2>&1
  echo "== log =="; tail -n 25 "$LOG" 2>&1
} >> "$OUT" 2>&1
echo fin >> "$OUT"
