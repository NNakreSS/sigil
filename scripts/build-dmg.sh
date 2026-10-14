#!/bin/bash
# Packs build/Sigil.app into a branded DMG (background, icon layout, volume icon) with dmgbuild.
#   scripts/build-dmg.sh <output.dmg>
# dmgbuild is installed once into .build/dmg-venv (pinned version).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?çıktı dosyası gerekli}"
VENV=".build/dmg-venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q "dmgbuild==1.6.7"
fi
[[ -f Packaging/dmg-background.tiff ]] || swift scripts/make-dmg-background.swift Packaging

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py \
  -D app=build/Sigil.app \
  -D background=Packaging/dmg-background.tiff \
  -D volicon=Packaging/AppIcon.icns \
  "Sigil" "$OUT" >/dev/null
echo "Hazır: $OUT"
