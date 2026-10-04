#!/usr/bin/env bash
# Build the menu bar app and install it.
#
#   scripts/install-app.sh            -> /Applications/Ullage.app
#   scripts/install-app.sh ~/Applications
#
# The bundle itself is scripts/bundle-app.sh, shared with the Homebrew formula.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST_DIR="${1:-/Applications}"
APP="$DEST_DIR/Ullage.app"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
scripts/bundle-app.sh "$STAGE" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Ullage.app/Contents/Info.plist")"

# Quit a running copy so the new one is what launches next, and wait for it
# to actually exit: `open` right after the quit request fails with -600.
osascript -e 'tell application id "com.sturdynut.ullage" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do pgrep -x UllageApp >/dev/null || break; sleep 0.1; done
rm -rf "$APP"
mkdir -p "$DEST_DIR"
cp -R "$STAGE/Ullage.app" "$APP"
echo "installed $APP ($VERSION)"
echo "launch:  open '$APP'"
echo "login item: System Settings > General > Login Items, add Ullage"
