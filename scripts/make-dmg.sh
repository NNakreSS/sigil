#!/bin/bash
# Local, ad-hoc signed DMG for your own Mac(s): dist/Sigil-<version>.dmg
# For distributing to other people use scripts/release.sh (Developer ID + notarization); without that, macOS
# Gatekeeper blocks apps downloaded from the internet.
#
#   VERSION=0.2.0 ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
VERSION="$VERSION" UNIVERSAL="${UNIVERSAL:-1}" ./scripts/make-app.sh

./scripts/build-dmg.sh "dist/Sigil-${VERSION}.dmg"
