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
echo "Building Ullage (${ULLAGE_BUILD_CONFIGURATION:-release})…"
scripts/bundle-app.sh "$STAGE" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Ullage.app/Contents/Info.plist")"

# Quit a running copy so the new one is what launches next, and wait for it
# to actually exit: `open` right after the quit request fails with -600.
if pgrep -x UllageApp >/dev/null; then
  osascript -e 'with timeout of 30 seconds' \
    -e 'tell application id "com.sturdynut.ullage" to quit' \
    -e 'end timeout' >/dev/null 2>&1 || true
  for _ in {1..300}; do pgrep -x UllageApp >/dev/null || break; sleep 0.1; done
  if pgrep -x UllageApp >/dev/null; then
    echo 'Ullage is still running. Quit it, then retry; the existing installation was kept.' >&2
    exit 1
  fi
fi
rm -rf "$APP"
mkdir -p "$DEST_DIR"
cp -R "$STAGE/Ullage.app" "$APP"
echo "installed $APP ($VERSION)"
echo "launch:  open '$APP'"
echo "login item: System Settings > General > Login Items, add Ullage"
