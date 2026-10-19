#!/usr/bin/env bash
# Build and restart the installed app and local HTTP service.
# Usage: scripts/dev.sh [installation-directory]
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Development checkout: $PWD ($(git branch --show-current))"
DEST_DIR="${1:-/Applications}"
swift build -c debug --product ullage
BIN_DIR="$(swift build -c debug --show-bin-path)"
ULLAGE_BUILD_CONFIGURATION=debug scripts/install-app.sh "$DEST_DIR"

# A Homebrew KeepAlive job would otherwise relaunch the installed service.
for label in sh.brew.ullage homebrew.mxcl.ullage; do
  job="gui/$(id -u)/$label"
  if launchctl print "$job" >/dev/null 2>&1; then launchctl bootout "$job"; fi
done
service_pattern='(^|/)ullage serve( |$)'
pkill -TERM -f "$service_pattern" || true
for _ in {1..50}; do
  if ! pgrep -f "$service_pattern" >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -f "$service_pattern" >/dev/null; then
  echo 'The previous Ullage HTTP service is still running; restart aborted.' >&2
  exit 1
fi

app_pid=''
service_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$service_pid" ]]; then kill "$service_pid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p .build/dev
"$BIN_DIR/ullage" serve --no-watch >.build/dev/service.log 2>&1 &
service_pid=$!
for _ in {1..50}; do
  if ! kill -0 "$service_pid" 2>/dev/null; then cat .build/dev/service.log; exit 1; fi
  if grep -q '^serving ' .build/dev/service.log &&
     curl --fail --silent --max-time 1 http://127.0.0.1:7878/ >/dev/null; then break; fi
  sleep 0.1
done
if ! grep -q '^serving ' .build/dev/service.log || ! kill -0 "$service_pid" 2>/dev/null; then
  cat .build/dev/service.log
  exit 1
fi
curl --fail --silent --max-time 1 http://127.0.0.1:7878/ >/dev/null

echo 'Running Ullage (Debug) and http://127.0.0.1:7878. Ctrl-C or Quit Ullage stops both.'
echo 'Service log: .build/dev/service.log; rerun task dev after editing.'
"$DEST_DIR/Ullage.app/Contents/MacOS/UllageApp" &
app_pid=$!
wait "$app_pid"
