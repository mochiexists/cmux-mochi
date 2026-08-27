#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Resolved from this script's repository root.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/fork-identity.env"

TAG="${1:-parity-recovery}"
if [[ ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "invalid tag: $TAG" >&2
  exit 2
fi

sanitize_bundle() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g'
}

sanitize_path() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

TAG_ID="$(sanitize_bundle "$TAG")"
TAG_SLUG="$(sanitize_path "$TAG")"
BUNDLE_ID="${CMUX_FORK_BUNDLE_ID}.debug.${TAG_ID}"
APP_NAME="${CMUX_FORK_APP_NAME} DEV ${TAG_SLUG}"
EXECUTABLE_NAME="${CMUX_FORK_APP_NAME} DEV"
APP="$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}/Build/Products/Debug/${APP_NAME}.app"
CLI="$APP/Contents/Resources/bin/cmux"
SOCKET="/tmp/cmux-debug-${TAG_SLUG}.sock"
DAEMON_SOCKET="$HOME/Library/Application Support/cmux/cmuxd-dev-${TAG_SLUG}.sock"
LOG="/tmp/cmux-debug-${TAG_SLUG}-force-quit.log"

if [[ ! -x "$CLI" ]]; then
  echo "tagged app is not built: $APP" >&2
  echo "build it with: CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag $TAG" >&2
  exit 1
fi

original_pairing=""
if original_pairing="$(defaults read "$BUNDLE_ID" mobile.iOSPairingHost.enabled 2>/dev/null)"; then
  :
else
  original_pairing="__unset__"
fi

restore_pairing_default() {
  if [[ "$original_pairing" == "__unset__" ]]; then
    defaults delete "$BUNDLE_ID" mobile.iOSPairingHost.enabled >/dev/null 2>&1 || true
  elif [[ "$original_pairing" == "1" ]]; then
    defaults write "$BUNDLE_ID" mobile.iOSPairingHost.enabled -bool true >/dev/null
  else
    defaults write "$BUNDLE_ID" mobile.iOSPairingHost.enabled -bool false >/dev/null
  fi
}
trap restore_pairing_default EXIT

# This is a desktop persistence journey, not a DeviceLink journey. Keeping the
# dedicated tagged bundle's listener off prevents an unrelated keychain ACL
# prompt from stalling launch after an ad-hoc signing hash changes.
defaults write "$BUNDLE_ID" mobile.iOSPairingHost.enabled -bool false

launch_app() {
  rm -f "$SOCKET" "$DAEMON_SOCKET"
  env \
    -u CMUX_DISABLE_SESSION_RESTORE \
    -u CMUX_WORKSPACE_ID \
    -u CMUX_SURFACE_ID \
    -u CMUX_TAB_ID \
    -u CMUX_PANEL_ID \
    CMUX_SOCKET_MODE=automation \
    CMUX_SOCKET_PATH="$SOCKET" \
    CMUXD_UNIX_PATH="$DAEMON_SOCKET" \
    CMUX_DEBUG_LOG="$LOG" \
    open -g "$APP"

  local deadline=$((SECONDS + 25))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCKET" ]] && cli ping >/dev/null 2>&1; then
      return
    fi
    sleep 0.2
  done
  echo "tagged socket did not become ready: $SOCKET" >&2
  exit 1
}

cli() {
  env \
    -u CMUX_SOCKET_PASSWORD \
    -u CMUX_WORKSPACE_ID \
    -u CMUX_SURFACE_ID \
    -u CMUX_TAB_ID \
    -u CMUX_PANEL_ID \
    CMUX_SOCKET_PATH="$SOCKET" \
    CMUX_BUNDLE_ID="$BUNDLE_ID" \
    "$CLI" "$@"
}

selected_surface() {
  local surface
  surface="$(cli list-pane-surfaces | awk '
    {
      for (field = 1; field <= NF; field += 1) {
        if ($field ~ /^surface:/) {
          print $field
          exit
        }
      }
    }
  ')"
  if [[ -z "$surface" ]]; then
    echo "list-pane-surfaces returned no surface" >&2
    exit 1
  fi
  printf '%s\n' "$surface"
}

wait_for_text() {
  local surface="$1"
  local expected="$2"
  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    if cli read-screen --surface "$surface" --scrollback --lines 700 2>/dev/null \
      | grep -Fq "$expected"; then
      return
    fi
    sleep 0.2
  done
  echo "terminal never displayed expected marker: $expected" >&2
  exit 1
}

seed_cycle() {
  local surface="$1"
  local token="$2"
  local prompt="${token}-PROMPT"
  local command
  command="i=1; while [ \$i -le 240 ]; do printf '${token}-%03d\\n' \"\$i\"; i=\$((i+1)); done; printf '${prompt}\\n'"
  cli send --surface "$surface" --enter -- "$command" >/dev/null
  wait_for_text "$surface" "${token}-240"
}

assert_cycle() {
  local surface="$1"
  local token="$2"
  local text
  text="$(cli read-screen --surface "$surface" --scrollback --lines 700)"
  for expected in "${token}-001" "${token}-120" "${token}-240" "${token}-PROMPT"; do
    if ! grep -Fq "$expected" <<<"$text"; then
      echo "restored scrollback is missing $expected" >&2
      exit 1
    fi
  done
}

force_quit() {
  local pid
  pid="$(pgrep -f "$APP/Contents/MacOS/$EXECUTABLE_NAME" | head -1)"
  if [[ -z "$pid" ]]; then
    echo "tagged app process not found" >&2
    exit 1
  fi
  kill -9 "$pid"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  echo "tagged app did not exit after SIGKILL" >&2
  exit 1
}

stop_existing_tagged_app() {
  local pid
  pid="$(pgrep -f "$APP/Contents/MacOS/$EXECUTABLE_NAME" | head -1 || true)"
  [[ -n "$pid" ]] || return 0
  kill -9 "$pid"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  echo "existing tagged app did not exit before the journey" >&2
  exit 1
}

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
first="CMUX-FORCE-QUIT-A-${run_id}"
second="CMUX-FORCE-QUIT-B-${run_id}"

stop_existing_tagged_app
launch_app
surface="$(selected_surface)"
seed_cycle "$surface" "$first"
sleep 10
force_quit

launch_app
surface="$(selected_surface)"
assert_cycle "$surface" "$first"
seed_cycle "$surface" "$second"
sleep 10
force_quit

launch_app
surface="$(selected_surface)"
assert_cycle "$surface" "$first"
assert_cycle "$surface" "$second"

echo "force-quit session continuity passed twice"
echo "tag: $TAG"
echo "surface: $surface"
echo "first token: $first"
echo "second token: $second"
