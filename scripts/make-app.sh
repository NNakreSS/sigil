#!/bin/bash
# Builds build/Sigil.app.
#
# Environment (all optional; defaults give a local, ad-hoc signed development build):
#   VERSION             marketing version, e.g. 1.2.0               (default: 0.0.0-dev)
#   BUILD_NUMBER        monotonically increasing integer for Sparkle (default: git commit count)
#   SIGN_IDENTITY       "Developer ID Application: …" or "-" for ad-hoc (default: -)
#   SPARKLE_FEED_URL    appcast URL; with SPARKLE_PUBLIC_KEY enables auto-updates
#   SPARKLE_PUBLIC_KEY  base64 EdDSA public key printed by Sparkle's generate_keys
#   UNIVERSAL           1 = arm64 + x86_64 (default: 0, host arch only)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-0}"

ARCH_FLAGS=()
if [[ "$UNIVERSAL" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Sigil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Sigil" "$APP/Contents/MacOS/Sigil"
# Drop build-machine rpaths (e.g. the Xcode toolchain); a shipped app should only search its own bundle and the OS.
otool -l "$APP/Contents/MacOS/Sigil" | awk '/LC_RPATH/{getline; getline; print $2}' | sort -u | while read -r rp; do
  case "$rp" in /usr/lib/swift|@executable_path/*|@loader_path*) ;; *) install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/Sigil" ;; esac
done
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (e.g. SwiftTerm's Metal shaders); Bundle.module looks for them in Resources.
for b in "$BIN_DIR"/*.bundle; do [ -d "$b" ] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"; done

# Sparkle. Sigil is not sandboxed, so Sparkle's XPC services are not needed (Sparkle docs: "Sandboxing").
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

SPARKLE_KEYS=""
if [[ -n "${SPARKLE_FEED_URL:-}" && -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sigil</string>
  <key>CFBundleDisplayName</key><string>Sigil</string>
  <key>CFBundleIdentifier</key><string>com.nakres.sigil</string>
  <key>CFBundleExecutable</key><string>Sigil</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>tr</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.nakres.sigil</string>
    <key>CFBundleURLSchemes</key><array><string>sigil</string></array>
  </dict></array>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Sigil</string>
${SPARKLE_KEYS}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Inside-out signing, no --deep (Sparkle docs). Developer ID builds get the hardened runtime and a secure
# timestamp, both required for notarization.
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi

FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$FW/Versions/B/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$FW/Versions/B/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$FW"
# SwiftPM resource bundles are only signable when they have a real bundle layout; flat ones (no Contents/Info.plist,
# as some Xcode versions produce) are plain resource folders and get sealed by the app's own signature.
for b in "$APP"/Contents/Resources/*.bundle; do
  [ -f "$b/Contents/Info.plist" ] && codesign "${SIGN_FLAGS[@]}" "$b"
done
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "Hazır: $APP  (sürüm $VERSION, build $BUILD_NUMBER, imza: $SIGN_IDENTITY)"
