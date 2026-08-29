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
BUNDLE_ID="${CMUX_FORCE_QUIT_BUNDLE_ID:-${CMUX_FORK_BUNDLE_ID}.debug.${TAG_ID}}"
APP_NAME="${CMUX_FORK_APP_NAME} DEV ${TAG_SLUG}"
APP="${CMUX_FORCE_QUIT_APP_PATH:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}/Build/Products/Debug/${APP_NAME}.app}"
EXECUTABLE_NAME="${CMUX_FORCE_QUIT_EXECUTABLE_NAME:-${CMUX_FORK_APP_NAME} DEV}"
CLI="$APP/Contents/Resources/bin/cmux"
SOCKET="${CMUX_FORCE_QUIT_SOCKET_PATH:-/tmp/cmux-debug-${TAG_SLUG}.sock}"
DAEMON_SOCKET="${CMUX_FORCE_QUIT_DAEMON_SOCKET_PATH:-$HOME/Library/Application Support/cmux/cmuxd-dev-${TAG_SLUG}.sock}"
LOG="${CMUX_FORCE_QUIT_LOG_PATH:-/tmp/cmux-debug-${TAG_SLUG}-force-quit.log}"
TEST_CWD="${CMUX_FORCE_QUIT_TEST_CWD:-$ROOT_DIR}"
SNAPSHOT="$HOME/Library/Application Support/cmux/session-${BUNDLE_ID}.json"
SNAPSHOT_PREVIOUS="$HOME/Library/Application Support/cmux/session-${BUNDLE_ID}-previous.json"
REPLAY_BOUNDARY_PREFIX="CMUX-SESSION-RESTORE-BOUNDARY:"
launched_pid=""

if [[ ! -x "$CLI" ]]; then
  echo "test app is not built: $APP" >&2
  if [[ -z "${CMUX_FORCE_QUIT_APP_PATH:-}" ]]; then
    echo "build it with: CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag $TAG" >&2
  fi
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

test_app_pids() {
  pgrep -f -x "$APP/Contents/MacOS/$EXECUTABLE_NAME" || true
}

cleanup_after_exit() {
  local result=$?
  restore_pairing_default
  if (( result != 0 )); then
    local pid
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      kill -9 "$pid" 2>/dev/null || true
    done < <(test_app_pids)
  fi
  return "$result"
}
trap cleanup_after_exit EXIT

# This is a desktop persistence journey, not a DeviceLink journey. Keeping the
# dedicated tagged bundle's listener off prevents an unrelated keychain ACL
# prompt from stalling launch after an ad-hoc signing hash changes.
defaults write "$BUNDLE_ID" mobile.iOSPairingHost.enabled -bool false

launch_app() {
  rm -f "$SOCKET" "$DAEMON_SOCKET"
  if [[ "${CMUX_FORCE_QUIT_DIRECT_EXEC:-0}" == "1" ]]; then
    (
      cd "$TEST_CWD"
      exec env \
        -u CMUX_DISABLE_SESSION_RESTORE \
        -u CMUX_WORKSPACE_ID \
        -u CMUX_SURFACE_ID \
        -u CMUX_TAB_ID \
        -u CMUX_PANEL_ID \
        CMUX_SOCKET_MODE=automation \
        CMUX_SOCKET_PATH="$SOCKET" \
        CMUX_BUNDLE_ID="$BUNDLE_ID" \
        CMUXD_UNIX_PATH="$DAEMON_SOCKET" \
        CMUX_DEBUG_LOG="$LOG" \
        "$APP/Contents/MacOS/$EXECUTABLE_NAME" >"$LOG.launch" 2>&1
    ) &
    launched_pid=$!
  else
    env \
      -u CMUX_DISABLE_SESSION_RESTORE \
      -u CMUX_WORKSPACE_ID \
      -u CMUX_SURFACE_ID \
      -u CMUX_TAB_ID \
      -u CMUX_PANEL_ID \
      CMUX_SOCKET_MODE=automation \
      CMUX_SOCKET_PATH="$SOCKET" \
      CMUX_BUNDLE_ID="$BUNDLE_ID" \
      CMUXD_UNIX_PATH="$DAEMON_SOCKET" \
      CMUX_DEBUG_LOG="$LOG" \
      open -g "$APP"
  fi

  local deadline=$((SECONDS + 25))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCKET" ]] && cli ping >/dev/null 2>&1; then
      return
    fi
    sleep 0.2
  done
  echo "test app socket did not become ready: $SOCKET" >&2
  if [[ -s "$LOG" ]]; then
    tail -n 120 "$LOG" >&2
  fi
  if [[ -s "$LOG.launch" ]]; then
    tail -n 120 "$LOG.launch" >&2
  fi
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
    $1 == "*" {
      for (field = 2; field <= NF; field += 1) {
        if ($field ~ /^surface:/) {
          print $field
          foundSelected = 1
          exit
        }
      }
    }
    {
      for (field = 1; field <= NF; field += 1) {
        if ($field ~ /^surface:/ && fallback == "") {
          fallback = $field
        }
      }
    }
    END {
      if (!foundSelected && fallback != "") {
        print fallback
      }
    }
  ')"
  if [[ -z "$surface" ]]; then
    echo "list-pane-surfaces returned no surface" >&2
    exit 1
  fi
  printf '%s\n' "$surface"
}

wait_for_surface_readable() {
  local surface="$1"
  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    if cli read-screen --surface "$surface" --scrollback --lines 1 >/dev/null 2>&1; then
      return
    fi
    sleep 0.2
  done
  echo "terminal did not become readable: $surface" >&2
  exit 1
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
  # This journey owns an isolated terminal and intentionally replaces whatever
  # transient login-shell startup process the reused CI runner reports. The
  # foreground-job guard is covered separately; do not let it make this
  # persistence gate race the runner's shell initialization.
  cli send --surface "$surface" --enter --force -- "$command" >/dev/null
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

assert_cycle_absent() {
  local surface="$1"
  local token="$2"
  local text
  text="$(cli read-screen --surface "$surface" --scrollback --lines 700)"
  if grep -Fq "${token}-" <<<"$text"; then
    echo "cleared scrollback unexpectedly contains $token" >&2
    exit 1
  fi
}

assert_cycle_history_absent() {
  local surface="$1"
  local token="$2"
  local text
  text="$(cli read-screen --surface "$surface" --scrollback --lines 700)"
  # Ghostty clear_screen erases history but intentionally retains the current
  # viewport. Early rows must disappear; the final screenful may remain.
  if grep -Fq "${token}-001" <<<"$text" || grep -Fq "${token}-120" <<<"$text"; then
    echo "cleared scrollback unexpectedly contains historical rows from $token" >&2
    exit 1
  fi
}

wait_for_cycle_absent() {
  local surface="$1"
  local token="$2"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    local text
    text="$(cli read-screen --surface "$surface" --scrollback --lines 700)"
    if ! grep -Fq "${token}-" <<<"$text"; then
      return
    fi
    sleep 0.2
  done
  echo "clear-history did not remove $token from terminal scrollback" >&2
  exit 1
}

wait_for_cycle_history_absent() {
  local surface="$1"
  local token="$2"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    local text
    text="$(cli read-screen --surface "$surface" --scrollback --lines 700)"
    if ! grep -Fq "${token}-001" <<<"$text" \
      && ! grep -Fq "${token}-120" <<<"$text"; then
      return
    fi
    sleep 0.2
  done
  echo "clear-history did not remove historical rows from $token" >&2
  exit 1
}

assert_snapshot_has_no_replay_boundary() {
  local snapshot
  for snapshot in "$SNAPSHOT" "$SNAPSHOT_PREVIOUS"; do
    [[ -f "$snapshot" ]] || continue
    if LC_ALL=C grep -aFq "$REPLAY_BOUNDARY_PREFIX" "$snapshot"; then
      echo "session snapshot contains an internal replay boundary: $snapshot" >&2
      exit 1
    fi
  done
}

assert_snapshot_cycle_absent() {
  local token="$1"
  if [[ -f "$SNAPSHOT" ]] && LC_ALL=C grep -aFq "${token}-" "$SNAPSHOT"; then
    echo "session snapshot resurrected cleared scrollback: $token" >&2
    exit 1
  fi
}

assert_snapshot_cycle_history_absent() {
  local token="$1"
  if [[ -f "$SNAPSHOT" ]] \
    && { LC_ALL=C grep -aFq "${token}-001" "$SNAPSHOT" \
      || LC_ALL=C grep -aFq "${token}-120" "$SNAPSHOT"; }; then
    echo "session snapshot resurrected cleared historical rows: $token" >&2
    exit 1
  fi
}

assert_snapshot_cycle_present() {
  local token="$1"
  if [[ ! -f "$SNAPSHOT" ]] || ! LC_ALL=C grep -aFq "${token}-240" "$SNAPSHOT"; then
    echo "session snapshot is missing expected scrollback: $token" >&2
    exit 1
  fi
}

wait_for_snapshot_cycle_present() {
  local token="$1"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if [[ -f "$SNAPSHOT" ]] && LC_ALL=C grep -aFq "${token}-240" "$SNAPSHOT"; then
      return
    fi
    sleep 0.2
  done
  assert_snapshot_cycle_present "$token"
}

wait_for_post_clear_snapshot() {
  local cleared_token="$1"
  local cleared_history_token="$2"
  local present_token="$3"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if [[ -f "$SNAPSHOT" ]] \
      && ! LC_ALL=C grep -aFq "${cleared_token}-" "$SNAPSHOT" \
      && ! LC_ALL=C grep -aFq "${cleared_history_token}-001" "$SNAPSHOT" \
      && ! LC_ALL=C grep -aFq "${cleared_history_token}-120" "$SNAPSHOT" \
      && LC_ALL=C grep -aFq "${present_token}-240" "$SNAPSHOT"; then
      return
    fi
    sleep 0.2
  done
  assert_snapshot_cycle_absent "$cleared_token"
  assert_snapshot_cycle_history_absent "$cleared_history_token"
  assert_snapshot_cycle_present "$present_token"
}

assert_previous_snapshot_cycle_absent() {
  local token="$1"
  if [[ -f "$SNAPSHOT_PREVIOUS" ]] \
    && LC_ALL=C grep -aFq "${token}-" "$SNAPSHOT_PREVIOUS"; then
    echo "previous session snapshot resurrected cleared scrollback: $token" >&2
    exit 1
  fi
}

assert_previous_snapshot_cycle_history_absent() {
  local token="$1"
  if [[ -f "$SNAPSHOT_PREVIOUS" ]] \
    && { LC_ALL=C grep -aFq "${token}-001" "$SNAPSHOT_PREVIOUS" \
      || LC_ALL=C grep -aFq "${token}-120" "$SNAPSHOT_PREVIOUS"; }; then
    echo "previous session snapshot resurrected cleared historical rows: $token" >&2
    exit 1
  fi
}

assert_previous_snapshot_cycle_present() {
  local token="$1"
  if [[ ! -f "$SNAPSHOT_PREVIOUS" ]] \
    || ! LC_ALL=C grep -aFq "${token}-240" "$SNAPSHOT_PREVIOUS"; then
    echo "previous session snapshot is missing expected scrollback: $token" >&2
    exit 1
  fi
}

wait_for_previous_snapshot_cycle_present() {
  local token="$1"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if [[ -f "$SNAPSHOT_PREVIOUS" ]] \
      && LC_ALL=C grep -aFq "${token}-240" "$SNAPSHOT_PREVIOUS"; then
      return
    fi
    sleep 0.2
  done
  assert_previous_snapshot_cycle_present "$token"
}

force_quit() {
  local pid
  if [[ -n "$launched_pid" ]] && kill -0 "$launched_pid" 2>/dev/null; then
    pid="$launched_pid"
  else
    pid="$(test_app_pids | tail -1)"
  fi
  if [[ -z "$pid" ]]; then
    echo "test app process not found" >&2
    exit 1
  fi
  kill -9 "$pid"
  wait "$pid" 2>/dev/null || true
  launched_pid=""
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  echo "test app did not exit after SIGKILL" >&2
  exit 1
}

stop_existing_test_app() {
  local pid
  local pids
  pids="$(test_app_pids)"
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done <<<"$pids"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if [[ -z "$(test_app_pids)" ]]; then
      return
    fi
    sleep 0.1
  done
  echo "existing test app did not exit before the journey" >&2
  exit 1
}

reset_test_state() {
  if [[ "${CMUX_FORCE_QUIT_PRESERVE_EXISTING_STATE:-0}" == "1" ]]; then
    return
  fi

  # The journey owns this dedicated bundle ID and socket namespace. Begin from
  # an empty session so a prior failed run cannot supply panes or foreground
  # jobs, while preserving state across the force-quits exercised below.
  rm -f -- \
    "$SNAPSHOT" \
    "$SNAPSHOT_PREVIOUS" \
    "$SOCKET" \
    "$SOCKET.lock" \
    "$DAEMON_SOCKET" \
    "$DAEMON_SOCKET.lock" \
    "$LOG" \
    "$LOG.launch"
}

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
first="CMUX-FORCE-QUIT-A-${run_id}"
second="CMUX-FORCE-QUIT-B-${run_id}"
third="CMUX-FORCE-QUIT-C-${run_id}"
workspace_name="CMUX-FORCE-QUIT-${run_id}"

stop_existing_test_app
reset_test_state
launch_app
cli new-workspace --name "$workspace_name" --cwd "$TEST_CWD" --focus true >/dev/null
surface="$(selected_surface)"
wait_for_surface_readable "$surface"
seed_cycle "$surface" "$first"
wait_for_snapshot_cycle_present "$first"
assert_snapshot_has_no_replay_boundary
force_quit

launch_app
surface="$(selected_surface)"
wait_for_surface_readable "$surface"
wait_for_text "$surface" "${first}-240"
assert_cycle "$surface" "$first"
seed_cycle "$surface" "$second"
wait_for_snapshot_cycle_present "$second"
assert_snapshot_has_no_replay_boundary
force_quit

launch_app
surface="$(selected_surface)"
wait_for_surface_readable "$surface"
wait_for_text "$surface" "${second}-240"
assert_cycle "$surface" "$first"
assert_cycle "$surface" "$second"

cli clear-history --surface "$surface" >/dev/null
wait_for_cycle_absent "$surface" "$first"
wait_for_cycle_history_absent "$surface" "$second"
seed_cycle "$surface" "$third"
assert_cycle_absent "$surface" "$first"
assert_cycle_history_absent "$surface" "$second"
wait_for_post_clear_snapshot "$first" "$second" "$third"
assert_snapshot_has_no_replay_boundary
assert_snapshot_cycle_absent "$first"
assert_snapshot_cycle_history_absent "$second"
assert_snapshot_cycle_present "$third"
force_quit

launch_app
surface="$(selected_surface)"
wait_for_surface_readable "$surface"
wait_for_text "$surface" "${third}-240"
assert_cycle "$surface" "$third"
assert_cycle_absent "$surface" "$first"
assert_cycle_history_absent "$surface" "$second"
assert_snapshot_has_no_replay_boundary
assert_snapshot_cycle_absent "$first"
assert_snapshot_cycle_history_absent "$second"
assert_snapshot_cycle_present "$third"
wait_for_previous_snapshot_cycle_present "$third"
assert_previous_snapshot_cycle_absent "$first"
assert_previous_snapshot_cycle_history_absent "$second"
assert_previous_snapshot_cycle_present "$third"

echo "force-quit session continuity passed twice and explicit clear stayed cleared"
echo "tag: $TAG"
echo "surface: $surface"
echo "first token: $first"
echo "second token: $second"
echo "post-clear token: $third"

if [[ "${CMUX_FORCE_QUIT_STOP_AFTER_SUCCESS:-0}" == "1" ]]; then
  force_quit
fi
