#!/usr/bin/env bash
# Launch the copied DMG app on a clean macOS runner using a disposable database.
set -euo pipefail
DMG="${1:?usage: scripts/smoke-app.sh <dmg>}"
STAGE="$(mktemp -d)"
APP_PID=""
trap '
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  hdiutil detach "$STAGE/mount" >/dev/null 2>&1 || true
  rm -rf "$STAGE"
' EXIT
mkdir "$STAGE/mount"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$STAGE/mount" >/dev/null
ditto "$STAGE/mount/Ullage.app" "$STAGE/Ullage.app"
ULLAGE_DB="$STAGE/smoke.db" "$STAGE/Ullage.app/Contents/MacOS/UllageApp" > "$STAGE/app.log" 2>&1 &
APP_PID=$!
for _ in {1..50}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    cat "$STAGE/app.log" >&2
    echo 'Packaged app exited during startup' >&2
    exit 1
  fi
  if [[ -s "$STAGE/smoke.db" ]] && [[ "$(sqlite3 -cmd '.timeout 1000' "$STAGE/smoke.db" "SELECT count(*) FROM sqlite_master WHERE type='table';")" -gt 0 ]]; then
    test "$(sqlite3 "$STAGE/smoke.db" 'PRAGMA quick_check;')" = ok
    sleep 2
    kill -0 "$APP_PID"
    echo 'Packaged app launched and initialized its database'
    exit 0
  fi
  sleep 0.2
done
cat "$STAGE/app.log" >&2
echo 'Packaged app did not initialize its database within 10 seconds' >&2
exit 1
