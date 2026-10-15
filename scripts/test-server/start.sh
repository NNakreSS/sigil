#!/usr/bin/env bash
# Builds and starts the throw-away Sigil test server (Ubuntu 24.04 + systemd).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=sigil-test-server
NAME=sigil-test-server
SSH_PORT=2222
HTTP_PORT=8080
ENV_FILE="$DIR/.env"

docker build -t "$IMAGE" "$DIR"

if docker container inspect "$NAME" >/dev/null 2>&1; then
  docker rm -f -v "$NAME" >/dev/null
fi

# systemd as PID 1 needs: privileged, the host cgroup namespace with a writable
# cgroupfs, and tmpfs on /run and /run/lock.
docker run -d \
  --name "$NAME" \
  --hostname sigil-test \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  --restart unless-stopped \
  -p 127.0.0.1:${SSH_PORT}:22 \
  -p 127.0.0.1:${HTTP_PORT}:80 \
  "$IMAGE" >/dev/null

# Wait for systemd to come up far enough to run commands.
for _ in $(seq 1 60); do
  state="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) break ;; esac
  sleep 1
done

# Fresh random root password for this container; kept only in .env (mode 600).
PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
umask 077
printf 'ROOT_PASSWORD=%s\n' "$PASSWORD" >"$ENV_FILE"
chmod 600 "$ENV_FILE"
printf 'root:%s\n' "$PASSWORD" | docker exec -i "$NAME" chpasswd
docker exec "$NAME" passwd -u root >/dev/null 2>&1 || true
unset PASSWORD

# Wait until sshd answers on the published port.
ok=0
for _ in $(seq 1 60); do
  if ssh-keyscan -T 2 -p "$SSH_PORT" 127.0.0.1 2>/dev/null | grep -q .; then
    ok=1
    break
  fi
  sleep 1
done
if [ "$ok" -ne 1 ]; then
  echo "HATA: sshd 127.0.0.1:${SSH_PORT} üzerinde yanıt vermiyor." >&2
  echo "Loglar: docker exec $NAME journalctl -u ssh -n 50" >&2
  exit 1
fi

cat <<EOF

Sigil test sunucusu hazır (Ubuntu 24.04, systemd).
  host:      127.0.0.1
  port:      ${SSH_PORT}
  kullanıcı: root
  şifre:     scripts/test-server/.env dosyasında
  nginx:     http://127.0.0.1:${HTTP_PORT}

Sunucu yeniden oluşturulduysa önce eski host key'i sil:
  ssh-keygen -R "[127.0.0.1]:${SSH_PORT}"
Durdurmak için: scripts/test-server/stop.sh
EOF
