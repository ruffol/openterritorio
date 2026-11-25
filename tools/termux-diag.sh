#!/data/data/com.termux/files/usr/bin/sh
# Diagnóstico del túnel escrito desde el propio teléfono.
SVDIR=/data/data/com.termux/files/usr/var/service
out=/sdcard/Download/diag.txt
{
  echo "== fecha =="; date -Is
  echo "== sv status cloudflared =="; sv status cloudflared 2>&1
  echo "== sv status openterritorio =="; sv status openterritorio 2>&1
  echo "== run de cloudflared =="; cat "$SVDIR/cloudflared/run" 2>&1
  echo "== contenido del servicio =="; ls -la "$SVDIR/cloudflared" 2>&1
  echo "== logs disponibles =="; ls -la /data/data/com.termux/files/usr/var/log 2>&1
  echo "== cola del log =="; tail -n 30 "$SVDIR/cloudflared/log/main/current" 2>&1
  echo "== config =="; cat /data/data/com.termux/files/home/.cloudflared/config.yml 2>&1
  echo "== archivos .cloudflared =="; ls -la /data/data/com.termux/files/home/.cloudflared 2>&1
  echo "== cloudflared version =="; cloudflared --version 2>&1
} > "$out" 2>&1
echo "listo" >> "$out"
