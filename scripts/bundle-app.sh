#!/usr/bin/env bash
# Build Ullage.app into a directory, without installing or launching it.
#
#   scripts/bundle-app.sh <out-dir>     -> <out-dir>/Ullage.app
#
# Shared by scripts/install-app.sh and the Homebrew formula, so both make the
# same bundle. SwiftPM produces a bare executable; macOS needs a bundle for a
# menu bar item (LSUIElement hides the Dock icon) and for the bundle identifier
# the collector keys its Application Support directory on. The signature is ad
# hoc: a local build of an unsandboxed tool, not a notarized download.
#
# ULLAGE_VERSION overrides the version; otherwise `git describe`, else "dev"
# (a release tarball has no .git, so Homebrew passes the version in).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:?usage: scripts/bundle-app.sh <out-dir>}"
VERSION="${ULLAGE_VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}"
LOGO="assets/branding/ullage-logo.png"

swift build -c release --product UllageApp

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Ullage.app/Contents/MacOS" "$STAGE/Ullage.app/Contents/Resources"
cp .build/release/UllageApp "$STAGE/Ullage.app/Contents/MacOS/UllageApp"

# App icon from the branding PNG. Build the standard .iconset (each size plus
# its @2x) and let iconutil produce the multi-resolution .icns; Finder, the
# Applications folder and the app switcher all read this.
ICON_KEY=""
if [[ -f "$LOGO" ]]; then
  ICONSET="$STAGE/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size"       "$LOGO" --out "$ICONSET/icon_${size}x${size}.png"     >/dev/null
    sips -z "$((size*2))" "$((size*2))" "$LOGO" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$STAGE/Ullage.app/Contents/Resources/AppIcon.icns"
  ICON_KEY="  <key>CFBundleIconFile</key>         <string>AppIcon</string>"
fi
cat > "$STAGE/Ullage.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Ullage</string>
  <key>CFBundleDisplayName</key>     <string>Ullage</string>
  <key>CFBundleIdentifier</key>      <string>com.sturdynut.ullage</string>
  <key>CFBundleExecutable</key>      <string>UllageApp</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSUIElement</key>             <true/>
${ICON_KEY}
  <key>NSHumanReadableCopyright</key> <string></string>
</dict>
</plist>
PLIST
codesign --force --sign - "$STAGE/Ullage.app" >/dev/null

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/Ullage.app"
cp -R "$STAGE/Ullage.app" "$OUT_DIR/Ullage.app"
echo "built $OUT_DIR/Ullage.app ($VERSION)"
