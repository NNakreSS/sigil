#!/bin/bash
# Signed, notarized release: build/Sigil.app → dist/Sigil-<version>.dmg + dist/appcast.xml
# Runs in GitHub Actions (see .github/workflows/release.yml) and can also run locally.
#
# Required environment:
#   VERSION              e.g. 1.2.0 (no leading "v")
#   SIGN_IDENTITY        "Developer ID Application: Name (TEAMID)" — must be in the keychain
#   GITHUB_REPOSITORY    owner/repo — releases and the appcast are served from here
#   SPARKLE_PUBLIC_KEY   base64 EdDSA public key
#   SPARKLE_PRIVATE_KEY  EdDSA private key (secret); fed to generate_appcast on stdin, never written to disk
#   Notarization, either an App Store Connect API key:
#     NOTARY_KEY_PATH  (path to AuthKey_XXXX.p8)  NOTARY_KEY_ID  NOTARY_ISSUER_ID
#   or a stored notarytool keychain profile:
#     NOTARY_PROFILE
# Optional:
#   BUILD_NUMBER         defaults to git commit count
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION gerekli}"
: "${SIGN_IDENTITY:?SIGN_IDENTITY gerekli}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY gerekli (owner/repo)}"
: "${SPARKLE_PUBLIC_KEY:?SPARKLE_PUBLIC_KEY gerekli}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY gerekli}"
[[ "$SIGN_IDENTITY" != "-" ]] || { echo "Yayın için Developer ID gerekli"; exit 1; }

notarize() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    : "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH ya da NOTARY_PROFILE gerekli}"
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}" --wait
  fi
}

FEED_URL="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/appcast.xml"
DIST="dist"
rm -rf "$DIST" && mkdir -p "$DIST"

# 1. Universal, hardened-runtime build signed with Developer ID.
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" UNIVERSAL=1 \
  SPARKLE_FEED_URL="$FEED_URL" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  ./scripts/make-app.sh

# 2. Notarize the app and staple the ticket so it opens offline too.
ditto -c -k --sequesterRsrc --keepParent build/Sigil.app "$DIST/notarize.zip"
notarize "$DIST/notarize.zip"
xcrun stapler staple build/Sigil.app
rm "$DIST/notarize.zip"

# 3. Branded DMG (APFS + lzfse, background, icon layout); sign, notarize, staple.
DMG="$DIST/Sigil-${VERSION}.dmg"
./scripts/build-dmg.sh "$DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# 4. Signed appcast pointing at this release's asset.
"$(dirname "$0")/../.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/${GITHUB_REPOSITORY}/releases/download/v${VERSION}/" \
  -o "$DIST/appcast.xml" \
  "$DIST" <<<"$SPARKLE_PRIVATE_KEY"

spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Yayın dosyaları hazır:"
ls -la "$DIST"
