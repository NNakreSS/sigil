#!/bin/bash
# Runs the current source as a local development build in place of the installed Sigil, without touching
# /Applications: same servers, keys and settings. To go back, quit it and open /Applications/Sigil.app.
#
#   ./scripts/try-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh
# One Sigil at a time: both share the same data and menu bar slot.
osascript -e 'tell application id "com.nakres.sigil" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "Sigil.app/Contents/MacOS/Sigil" >/dev/null || break; sleep 0.5; done
open -n build/Sigil.app
echo "Yerel derleme açıldı (sürüm 0.0.0-dev). Geri dönmek için: Sigil'den çık, sonra /Applications/Sigil.app'i aç."
