#!/usr/bin/env bash
# Develop against the installed app and local HTTP service, then hand them back.
#
#   scripts/dev.sh [installation-directory]        Debug app + service from this
#                                                  checkout, in this terminal
#   scripts/dev.sh ready [installation-directory]  Release app installed; Shire
#                                                  (or you) runs it again
#
# When Shire supervises Ullage (services `ullage` and `ullage-serve` in
# ~/.config/shire/config.yaml), dev mode stops both first, so Shire neither
# reopens the app you quit nor fights the checkout's service for port 7878.
# They stay stopped after you quit, until `ready`. Override the names with
# ULLAGE_SHIRE_APP / ULLAGE_SHIRE_SERVE; ULLAGE_SHIRE=0 leaves Shire alone.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=dev
if [[ "${1:-}" == ready ]]; then MODE=ready; shift; fi
DEST_DIR="${1:-/Applications}"
SHIRE_APP="${ULLAGE_SHIRE_APP:-ullage}"
SHIRE_SERVE="${ULLAGE_SHIRE_SERVE:-ullage-serve}"
service_pattern='(^|/)ullage serve( |$)'

# Shire is in charge only if it is installed and lists both services.
shire_manages_ullage() {
  [[ "${ULLAGE_SHIRE:-1}" != 0 ]] || return 1
  command -v shire >/dev/null 2>&1 || return 1
  local status
  status="$(shire status 2>/dev/null)" || return 1
  grep -qE "^${SHIRE_APP}[[:space:]]" <<<"$status" && grep -qE "^${SHIRE_SERVE}[[:space:]]" <<<"$status"
}

# Any `ullage serve` still holding the port, Homebrew's or a checkout's.
stop_other_services() {
  # A Homebrew KeepAlive job would otherwise relaunch the installed service.
  for label in sh.brew.ullage homebrew.mxcl.ullage; do
    job="gui/$(id -u)/$label"
    if launchctl print "$job" >/dev/null 2>&1; then launchctl bootout "$job"; fi
  done
  pkill -TERM -f "$service_pattern" || true
  for _ in {1..50}; do
    if ! pgrep -f "$service_pattern" >/dev/null; then return 0; fi
    sleep 0.1
  done
  echo 'The previous Ullage HTTP service is still running; restart aborted.' >&2
  exit 1
}

if [[ "$MODE" == ready ]]; then
  echo "Handing Ullage back: Release build of $(git branch --show-current 2>/dev/null || echo 'this checkout')"
  managed=0
  if shire_manages_ullage; then managed=1; fi
  # Already stopped after a dev session; stopped here too in case there was
  # none, or Shire would reopen the old app the moment the install quits it.
  if [[ "$managed" == 1 ]]; then
    shire stop "$SHIRE_APP" || true
    shire stop "$SHIRE_SERVE" || true
    # A failed build or install leaves Shire paused rather than running a
    # half-replaced app; say so.
    trap 'status=$?; if [[ $status -ne 0 ]]; then echo "Shire is still paused. Fix the error, then: scripts/dev.sh ready" >&2; fi' EXIT
  fi
  # Quits the Debug app (which ends a dev session still running elsewhere).
  scripts/install-app.sh "$DEST_DIR"
  stop_other_services
  if [[ "$managed" == 1 ]]; then
    # The app first: the service depends on it. `restart` runs the service's
    # own build step, so Shire serves this checkout's Release binary.
    shire start "$SHIRE_APP"
    shire restart "$SHIRE_SERVE"
    echo "Shire is running $SHIRE_APP and $SHIRE_SERVE again."
  else
    open "$DEST_DIR/Ullage.app"
    echo "Opened the Release app. Start 'ullage serve --no-watch' yourself if you use the phone page."
  fi
  exit 0
fi

echo "Development checkout: $PWD ($(git branch --show-current))"
swift build -c debug --product ullage
BIN_DIR="$(swift build -c debug --show-bin-path)"

# Only once the build has worked: a failed build leaves everything running.
shire_paused=0
if shire_manages_ullage; then
  shire stop "$SHIRE_APP"
  shire stop "$SHIRE_SERVE"
  shire_paused=1
  echo "Paused Shire's $SHIRE_APP and $SHIRE_SERVE until: scripts/dev.sh ready"
fi

ULLAGE_BUILD_CONFIGURATION=debug scripts/install-app.sh "$DEST_DIR"
stop_other_services

app_pid=''
service_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$service_pid" ]]; then kill "$service_pid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  if [[ "$shire_paused" == 1 ]]; then
    echo "Shire is still paused, with the Debug app installed. When it's ready: scripts/dev.sh ready"
  fi
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
echo 'Service log: .build/dev/service.log. Rerun scripts/dev.sh after editing.'
"$DEST_DIR/Ullage.app/Contents/MacOS/UllageApp" &
app_pid=$!
wait "$app_pid"
