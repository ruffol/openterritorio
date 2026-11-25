#!/data/data/com.termux/files/usr/bin/sh
# Comprueba por qué cloudflared no conecta: DNS y puertos del edge.
OUT=/sdcard/Download/diag2.txt
{
  echo "== fecha =="; date -Is
  echo "== resolv.conf =="; cat /etc/resolv.conf 2>&1 | head -5
  echo "== DNS con libc (getent) =="; getent hosts region1.v2.argotunnel.com 2>&1 | head -3
  echo "== DNS con libc (ping) =="; ping -c1 -W3 region1.v2.argotunnel.com 2>&1 | head -3
  echo "== TCP 7844 =="
  for ip in 198.41.192.7 198.41.192.167 198.41.200.13 198.41.200.113; do
    timeout 6 sh -c "echo > /dev/tcp/$ip/7844" 2>/dev/null && echo "$ip:7844 OK" || echo "$ip:7844 BLOQUEADO"
  done
  echo "== TCP 443 =="
  for ip in 198.41.192.7 198.41.200.13; do
    timeout 6 sh -c "echo > /dev/tcp/$ip/443" 2>/dev/null && echo "$ip:443 OK" || echo "$ip:443 BLOQUEADO"
  done
  echo "== version =="; /data/data/com.termux/files/home/bin/cloudflared-edge --version 2>&1
  echo "== run actual =="; cat /data/data/com.termux/files/usr/var/service/cloudflared/run 2>&1
} > "$OUT" 2>&1
echo fin >> "$OUT"
