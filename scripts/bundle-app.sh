#!/usr/bin/env bash
# Build Ullage.app into a directory, without installing or launching it.
#
#   scripts/bundle-app.sh <out-dir>     -> <out-dir>/Ullage.app
#
# Shared by scripts/install-app.sh and the Homebrew formula, so both make the
# same bundle. SwiftPM produces a bare executable; macOS needs a bundle for a
# menu bar item (LSUIElement hides the Dock icon) and for the bundle identifier
# the collector keys its Application Support directory on.
#
# ULLAGE_VERSION overrides the version; otherwise `git describe`, else "dev"
# (a release tarball has no .git, so Homebrew passes the version in).
# SWIFT_BUILD_FLAGS is passed to `swift build`: Homebrew builds inside its own
# sandbox, where SwiftPM's sandbox can't start, so it passes --disable-sandbox.
# CODE_SIGN_IDENTITY selects a Developer ID certificate; defaults to ad hoc.
# ULLAGE_BUILD_CONFIGURATION selects debug or release (the default).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:?usage: scripts/bundle-app.sh <out-dir>}"
CONFIGURATION="${ULLAGE_BUILD_CONFIGURATION:-release}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo 'ULLAGE_BUILD_CONFIGURATION must be debug or release' >&2; exit 1 ;;
esac
VERSION="${ULLAGE_VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}"
LOGO="assets/branding/ullage-logo.png"

# Word splitting is intentional: callers supply multiple SwiftPM arguments.
# shellcheck disable=SC2086
swift build ${SWIFT_BUILD_FLAGS:-} -c "$CONFIGURATION" --product UllageApp
# shellcheck disable=SC2086
BIN_DIR="$(swift build ${SWIFT_BUILD_FLAGS:-} -c "$CONFIGURATION" --show-bin-path)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Ullage.app/Contents/MacOS" "$STAGE/Ullage.app/Contents/Resources"
cp "$BIN_DIR/UllageApp" "$STAGE/Ullage.app/Contents/MacOS/UllageApp"

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
if [[ "${CODE_SIGN_IDENTITY:--}" == "-" ]]; then
  codesign --force --sign - "$STAGE/Ullage.app" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$STAGE/Ullage.app"
fi
plutil -lint "$STAGE/Ullage.app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$STAGE/Ullage.app"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/Ullage.app"
cp -R "$STAGE/Ullage.app" "$OUT_DIR/Ullage.app"
echo "built $OUT_DIR/Ullage.app ($VERSION)"
