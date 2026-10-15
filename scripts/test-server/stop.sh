#!/usr/bin/env bash
# Stops and removes the Sigil test server container (and its Docker volume).
set -euo pipefail

NAME=sigil-test-server

if docker container inspect "$NAME" >/dev/null 2>&1; then
  docker rm -f -v "$NAME" >/dev/null
  echo "Test sunucusu durduruldu ve silindi."
else
  echo "Çalışan bir test sunucusu yok."
fi
