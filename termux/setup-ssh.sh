#!/data/data/com.termux/files/usr/bin/bash
# Habilita sshd por clave para controlar el teléfono desde el PC.
set -uo pipefail
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export SVDIR="$PREFIX/var/service"

LOG=/sdcard/Download/opssh.log
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== ssh setup $(date) ==="
command -v sshd >/dev/null 2>&1 || pkg install -y openssh >>"$LOG" 2>&1 || { echo "ERROR openssh"; exit 1; }

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
if ! grep -qF "$(cat /sdcard/Download/phone.pub)" "$HOME/.ssh/authorized_keys"; then
  cat /sdcard/Download/phone.pub >>"$HOME/.ssh/authorized_keys"
fi
chmod 600 "$HOME/.ssh/authorized_keys"

CFG="$PREFIX/etc/ssh/sshd_config"
if [ -f "$CFG" ]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$CFG"
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$CFG"
  grep -q '^Port ' "$CFG" || echo 'Port 8022' >>"$CFG"
fi

if [ ! -x "$SVDIR/sshd/run" ]; then
  mkdir -p "$SVDIR/sshd"
  cat > "$SVDIR/sshd/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
export PREFIX=$PREFIX
export HOME=$HOME
export PATH=$PREFIX/bin:/system/bin:/system/xbin
exec sshd -D -e
EOF
  chmod +x "$SVDIR/sshd/run"
fi
sv up sshd 2>/dev/null || true
sleep 2

echo "whoami=$(whoami)" > /sdcard/Download/opssh.info
echo "port=8022" >> /sdcard/Download/opssh.info
echo "sv status:" >> /sdcard/Download/opssh.info
sv status sshd >> /sdcard/Download/opssh.info 2>&1
cat /sdcard/Download/opssh.info
echo "=== ssh setup fin ==="
