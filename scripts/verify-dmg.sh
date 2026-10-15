#!/usr/bin/env bash
# Check the actual mounted deliverable, including its universal executable.
set -euo pipefail
DMG="${1:?usage: scripts/verify-dmg.sh <dmg> <version>}"
VERSION="${2:?usage: scripts/verify-dmg.sh <dmg> <version>}"
MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT"' EXIT
hdiutil verify "$DMG" >/dev/null
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
APP="$MOUNT/Ullage.app"
PLIST="$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/UllageApp"
test -s "$APP/Contents/Resources/AppIcon.icns"
test "$(readlink "$MOUNT/Applications")" = /Applications
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = com.sturdynut.ullage
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = 14.0
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST")" = true
plutil -lint "$PLIST"
for arch in arm64 x86_64; do
  lipo "$APP/Contents/MacOS/UllageApp" -verify_arch "$arch"
done
codesign --verify --deep --strict "$APP"
echo 'DMG verified: app, icon, version, signature, both architectures, and Applications shortcut'
