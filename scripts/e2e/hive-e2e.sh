#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/e2e/hive-e2e.sh [--tag TAG] [--artifact-dir DIR]
       [--derived-data DIR] [--timeout-seconds N]

Runs a real Mac-to-Mac Hive journey with two isolated tagged Debug apps on
one Mac. The apps communicate over DeviceLink's debug loopback route.
EOF
}

TAG="hive-e2e-${GITHUB_RUN_ID:-$$}"
ARTIFACT_DIR=""
DERIVED_DATA_ROOT="${CMUX_E2E_DERIVED_DATA_ROOT:-$HOME/src/dd-cmux-remote-nightly/phase3b}"
TIMEOUT_SECONDS="${CMUX_E2E_TIMEOUT_SECONDS:-180}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
    --derived-data) DERIVED_DATA_ROOT="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: --timeout-seconds must be a positive integer" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[[ "$REPO_ROOT" != "/" && "$REPO_ROOT" != "$HOME" ]] || {
  echo "error: refusing to run with repository root $REPO_ROOT" >&2
  exit 2
}

# shellcheck source=scripts/fork-identity.env
source "$REPO_ROOT/scripts/fork-identity.env"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$REPO_ROOT/scripts/lib/mobile-attach.sh"

A_TAG="${TAG}-host"
B_TAG="${TAG}-client"
cmux_attach_validate_dev_tag "$A_TAG"
cmux_attach_validate_dev_tag "$B_TAG"
A_SLUG="$(cmux_attach__slug "$A_TAG")"
B_SLUG="$(cmux_attach__slug "$B_TAG")"
A_BUNDLE_ID="$(cmux_attach_mac_bundle_id "$A_TAG")"
B_BUNDLE_ID="$(cmux_attach_mac_bundle_id "$B_TAG")"
A_SOCKET="$(cmux_attach_socket_path "$A_TAG")"
B_SOCKET="$(cmux_attach_socket_path "$B_TAG")"
A_DERIVED_DATA="$DERIVED_DATA_ROOT/host"
B_DERIVED_DATA="$DERIVED_DATA_ROOT/client"

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="${RUNNER_TEMP:-$HOME/src/task-data/cmux-remote-nightly}/hive-e2e-${TAG}-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$ARTIFACT_DIR" "$A_DERIVED_DATA" "$B_DERIVED_DATA"
umask 077

export DEVELOPER_DIR="/Applications/Xcode-26.6.app/Contents/Developer"
[[ -d "$DEVELOPER_DIR" ]] || {
  echo "error: required Xcode not found at $DEVELOPER_DIR" >&2
  exit 1
}

# Never inherit the supervising cmux session into either tagged app or CLI.
unset CMUX_SOCKET CMUX_SOCKET_PATH CMUX_SOCKET_PASSWORD CMUX_BUNDLED_CLI_PATH
unset CMUX_BUNDLE_ID CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID
unset CMUX_WINDOW_ID CMUX_TERMINAL_LIFECYCLE_ID CMUXD_UNIX_PATH CMUX_DEBUG_LOG
unset CMUX_PORT CMUX_PORT_END CMUX_PORT_RANGE CMUX_SHELL_INTEGRATION
unset CMUX_SHELL_INTEGRATION_DIR CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION

A_PID=""
B_PID=""
RUN_STARTED="$(date +%s)"

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [[ -n "$B_PID" ]] && kill -0 "$B_PID" 2>/dev/null; then
    kill "$B_PID" 2>/dev/null || true
    wait "$B_PID" 2>/dev/null || true
  fi
  if [[ -n "$A_PID" ]] && kill -0 "$A_PID" 2>/dev/null; then
    kill "$A_PID" 2>/dev/null || true
    wait "$A_PID" 2>/dev/null || true
  fi
  if [[ ! -S "$A_SOCKET" ]] || [[ -z "$(lsof -t "$A_SOCKET" 2>/dev/null || true)" ]]; then
    cmux_attach_remove_stale_socket "$A_TAG" || true
  fi
  if [[ ! -S "$B_SOCKET" ]] || [[ -z "$(lsof -t "$B_SOCKET" 2>/dev/null || true)" ]]; then
    cmux_attach_remove_stale_socket "$B_TAG" || true
  fi
  exit "$result"
}
trap cleanup EXIT INT TERM

wait_until() {
  local description="$1"
  shift
  local started
  started="$(date +%s)"
  while (( $(date +%s) - started < TIMEOUT_SECONDS )); do
    if "$@"; then
      return 0
    fi
    sleep 1
  done
  echo "error: timed out waiting for $description" >&2
  return 1
}

cli_for() {
  local socket="$1" bundle_id="$2" cli_path="$3"
  shift 3
  env \
    -u CMUX_SOCKET \
    -u CMUX_SOCKET_PASSWORD \
    -u CMUX_WORKSPACE_ID \
    -u CMUX_SURFACE_ID \
    -u CMUX_TAB_ID \
    -u CMUX_PANEL_ID \
    -u CMUX_WINDOW_ID \
    CMUX_SOCKET_PATH="$socket" \
    CMUX_BUNDLE_ID="$bundle_id" \
    CMUX_BUNDLED_CLI_PATH="$cli_path" \
    "$cli_path" "$@"
}

cli_a() { cli_for "$A_SOCKET" "$A_BUNDLE_ID" "$A_CLI" "$@"; }
cli_b() { cli_for "$B_SOCKET" "$B_BUNDLE_ID" "$B_CLI" "$@"; }

socket_a_ready() { [[ -S "$A_SOCKET" ]] && cli_a rpc system.ping '{}' >/dev/null 2>&1; }
socket_b_ready() { [[ -S "$B_SOCKET" ]] && cli_b rpc system.ping '{}' >/dev/null 2>&1; }

launch_a() {
  local executable="$A_APP/Contents/MacOS/$CMUX_FORK_APP_NAME DEV"
  [[ -x "$executable" ]] || { echo "error: host executable missing: $executable" >&2; return 1; }
  (
    cd "$REPO_ROOT"
    exec env \
      CMUX_FORK_BUNDLE_ID="$A_BUNDLE_ID" \
      CMUXD_UNIX_PATH="$ARTIFACT_DIR/host-cmuxd.sock" \
      CMUX_SOCKET_PATH="$A_SOCKET" \
      CMUX_DEBUG_LOG="$ARTIFACT_DIR/host-debug.log" \
      CMUX_TAG="$A_SLUG" \
      CMUX_AUTH_CALLBACK_SCHEME="cmux-dev-$A_SLUG" \
      CMUX_SOCKET_ENABLE=1 \
      CMUX_SOCKET_MODE=allowAll \
      CMUX_DISABLE_SESSION_RESTORE=1 \
      CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 \
      CMUX_E2E_DEVICELINK_STATE_DIR="$ARTIFACT_DIR/host-devicelink-state" \
      CMUX_E2E_HIVE_STATE_DIR="$ARTIFACT_DIR/host-hive-state" \
      CMUXTERM_REPO_ROOT="$REPO_ROOT" \
      CMUX_BUNDLED_CLI_PATH="$A_CLI" \
      CMUX_SHELL_INTEGRATION_DIR="$A_APP/Contents/Resources/shell-integration" \
      "$executable" >>"$ARTIFACT_DIR/host-stdio.log" 2>&1
  ) &
  A_PID=$!
  wait_until "host tagged socket" socket_a_ready
}

launch_b() {
  local executable="$B_APP/Contents/MacOS/$CMUX_FORK_APP_NAME DEV"
  [[ -x "$executable" ]] || { echo "error: client executable missing: $executable" >&2; return 1; }
  (
    cd "$REPO_ROOT"
    exec env \
      CMUX_FORK_BUNDLE_ID="$B_BUNDLE_ID" \
      CMUXD_UNIX_PATH="$ARTIFACT_DIR/client-cmuxd.sock" \
      CMUX_SOCKET_PATH="$B_SOCKET" \
      CMUX_DEBUG_LOG="$ARTIFACT_DIR/client-debug.log" \
      CMUX_TAG="$B_SLUG" \
      CMUX_AUTH_CALLBACK_SCHEME="cmux-dev-$B_SLUG" \
      CMUX_SOCKET_ENABLE=1 \
      CMUX_SOCKET_MODE=allowAll \
      CMUX_DISABLE_SESSION_RESTORE=1 \
      CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 \
      CMUX_E2E_DEVICELINK_STATE_DIR="$ARTIFACT_DIR/client-devicelink-state" \
      CMUX_E2E_HIVE_STATE_DIR="$ARTIFACT_DIR/client-hive-state" \
      CMUXTERM_REPO_ROOT="$REPO_ROOT" \
      CMUX_BUNDLED_CLI_PATH="$B_CLI" \
      CMUX_SHELL_INTEGRATION_DIR="$B_APP/Contents/Resources/shell-integration" \
      "$executable" >>"$ARTIFACT_DIR/client-stdio.log" 2>&1
  ) &
  B_PID=$!
  wait_until "client tagged socket" socket_b_ready
}

stop_a() {
  [[ -n "$A_PID" ]] || return 0
  kill -KILL "$A_PID" 2>/dev/null || true
  wait "$A_PID" 2>/dev/null || true
  A_PID=""
  cmux_attach_remove_stale_socket "$A_TAG"
}

host_screen_contains() {
  cli_a read-screen --workspace "$A_WORKSPACE_ID" --scrollback --lines 500 2>/dev/null \
    | grep -Fq -- "$1"
}

host_screen_matches() {
  cli_a read-screen --workspace "$A_WORKSPACE_ID" --scrollback --lines 500 2>/dev/null \
    | grep -Eq -- "$1"
}

client_connected() {
  cli_b hive status --json >"$ARTIFACT_DIR/client-status.json" 2>>"$ARTIFACT_DIR/client-status.log" || return 1
  STATUS_PATH="$ARTIFACT_DIR/client-status.json" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["STATUS_PATH"]) as file:
    status = json.load(file)
raise SystemExit(0 if status.get("connected") and status.get("workspaces") else 1)
PY
}

host_has_two_surfaces() {
  cli_a rpc surface.list "{\"workspace_id\":\"$A_WORKSPACE_ID\"}" \
    >"$ARTIFACT_DIR/host-surfaces.json" 2>>"$ARTIFACT_DIR/host-surfaces.log" || return 1
  SURFACES_PATH="$ARTIFACT_DIR/host-surfaces.json" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["SURFACES_PATH"]) as file:
    response = json.load(file)
result = response.get("result", response)
raise SystemExit(0 if len(result.get("surfaces", [])) >= 2 else 1)
PY
}

client_has_two_remote_terminals() {
  cli_b hive list --json >"$ARTIFACT_DIR/client-list-two.json" 2>/dev/null || return 1
  LIST_PATH="$ARTIFACT_DIR/client-list-two.json" REMOTE_WORKSPACE_ID="$REMOTE_WORKSPACE_ID" \
    /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["LIST_PATH"]) as file:
    payload = json.load(file)
for workspace in payload.get("workspaces", []):
    if workspace.get("id") == os.environ["REMOTE_WORKSPACE_ID"]:
        raise SystemExit(0 if len(workspace.get("terminals", [])) >= 2 else 1)
raise SystemExit(1)
PY
}

single_shared_attachment_ready() {
  cli_b hive status --json >"$ARTIFACT_DIR/client-shared-status.json" 2>/dev/null || return 1
  STATUS_PATH="$ARTIFACT_DIR/client-shared-status.json" REMOTE_SURFACE_ID="$REMOTE_SURFACE_ID" \
    /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["STATUS_PATH"]) as file:
    status = json.load(file)
matches = [item for item in status.get("attachments", [])
           if item.get("remote_surface_id") == os.environ["REMOTE_SURFACE_ID"]]
raise SystemExit(0 if len(matches) == 1
                 and matches[0].get("local_mount_count") == 2
                 and matches[0].get("remote_registration_count") == 1 else 1)
PY
}

host_pairing_revoked() {
  cli_a rpc mobile.pairing.device.list '{}' >"$ARTIFACT_DIR/host-paired-devices-after-remove.json" 2>/dev/null || return 1
  DEVICES_PATH="$ARTIFACT_DIR/host-paired-devices-after-remove.json" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["DEVICES_PATH"]) as file:
    response = json.load(file)
result = response.get("result", response)
raise SystemExit(0 if result.get("devices") == [] else 1)
PY
}

client_window_count_unchanged() {
  cli_b rpc window.list '{}' >"$ARTIFACT_DIR/client-windows-after-restart.json" 2>/dev/null || return 1
  WINDOWS_PATH="$ARTIFACT_DIR/client-windows-after-restart.json" \
    EXPECTED_WINDOW_COUNT="$WINDOW_COUNT_BEFORE" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["WINDOWS_PATH"]) as file:
    response = json.load(file)
result = response.get("result", response)
raise SystemExit(0 if len(result["windows"]) == int(os.environ["EXPECTED_WINDOW_COUNT"]) else 1)
PY
}

echo "==> Building tagged Hive host: $A_TAG"
(
  cd "$REPO_ROOT"
  CMUX_SKIP_ZIG_BUILD=1 CMUX_RELOAD_NO_GLOBAL_CLI_LINKS=1 \
    ./scripts/reload.sh --tag "$A_TAG" --derived-data "$A_DERIVED_DATA" --no-global-cli-links
) 2>&1 | tee "$ARTIFACT_DIR/host-build.log"

echo "==> Building tagged Hive client: $B_TAG"
(
  cd "$REPO_ROOT"
  CMUX_SKIP_ZIG_BUILD=1 CMUX_RELOAD_NO_GLOBAL_CLI_LINKS=1 \
    ./scripts/reload.sh --tag "$B_TAG" --derived-data "$B_DERIVED_DATA" --no-global-cli-links
) 2>&1 | tee "$ARTIFACT_DIR/client-build.log"

A_APP="$A_DERIVED_DATA/Build/Products/Debug/$CMUX_FORK_APP_NAME DEV $A_SLUG.app"
B_APP="$B_DERIVED_DATA/Build/Products/Debug/$CMUX_FORK_APP_NAME DEV $B_SLUG.app"
A_CLI="$A_APP/Contents/Resources/bin/cmux"
B_CLI="$B_APP/Contents/Resources/bin/cmux"
[[ -d "$A_APP" && -x "$A_CLI" && -d "$B_APP" && -x "$B_CLI" ]] || {
  echo "error: tagged build products are missing" >&2
  exit 1
}

cmux_attach_enable_pairing_host "$A_TAG"
launch_a
launch_b

MARKER="HIVE-$(jot -r 1 100000 999999)-$(date +%s)"
A_WORKSPACE_NAME="hive-host-$MARKER"
A_WORKSPACE_RESPONSE="$(cli_a rpc workspace.create "{\"cwd\":\"$REPO_ROOT\",\"title\":\"$A_WORKSPACE_NAME\",\"focus\":true}")"
A_WORKSPACE_ID="$(WORKSPACE_RESPONSE="$A_WORKSPACE_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["WORKSPACE_RESPONSE"])
result = response.get("result", response)
print(result["workspace_id"])
PY
)"

# Keep the client's original selection as a focus-preservation witness.
B_CURRENT_BEFORE="$(cli_b rpc workspace.current '{}')"
B_SELECTED_BEFORE="$(CURRENT_RESPONSE="$B_CURRENT_BEFORE" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["CURRENT_RESPONSE"])
result = response.get("result", response)
print(result["workspace_id"])
PY
)"

wait_until "host DeviceLink management" cli_a rpc mobile.pairing.device.list '{}'
PAIRING_RESPONSE="$(cli_a rpc mobile.pairing.code.create '{"ttl_seconds":600}')"
PAIRING_URL="$(PAIRING_RESPONSE="$PAIRING_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os
import urllib.parse

response = json.loads(os.environ["PAIRING_RESPONSE"])
result = response.get("result", response)
url = result["pairing_url"]
query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
if query.get("v") != ["3"] or not query.get("t") or not query.get("r"):
    raise SystemExit("pairing code was not a valid v3 link")
print(url)
PY
)"

echo "==> Pairing Hive client to host over loopback"
cli_b hive pair "$PAIRING_URL" --json >"$ARTIFACT_DIR/client-pair.json"
wait_until "Hive workspace discovery" client_connected

PAIRING_ID="$(STATUS_PATH="$ARTIFACT_DIR/client-status.json" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["STATUS_PATH"]) as file:
    status = json.load(file)
print(status["paired_macs"][0]["id"])
PY
)"
REMOTE_WORKSPACE_ID="$(STATUS_PATH="$ARTIFACT_DIR/client-status.json" HOST_WORKSPACE_ID="$A_WORKSPACE_ID" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["STATUS_PATH"]) as file:
    status = json.load(file)
for workspace in status["workspaces"]:
    if workspace.get("remote_workspace_id") == os.environ["HOST_WORKSPACE_ID"]:
        print(workspace["id"])
        break
else:
    raise SystemExit("host workspace was not discovered")
PY
)"
REMOTE_SURFACE_ID="$(STATUS_PATH="$ARTIFACT_DIR/client-status.json" REMOTE_WORKSPACE_ID="$REMOTE_WORKSPACE_ID" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["STATUS_PATH"]) as file:
    status = json.load(file)
for workspace in status["workspaces"]:
    if workspace.get("id") == os.environ["REMOTE_WORKSPACE_ID"]:
        print(workspace["terminals"][0]["id"])
        break
else:
    raise SystemExit("remote terminal was not discovered")
PY
)"

OPEN_RESPONSE="$(cli_b hive open "$REMOTE_WORKSPACE_ID" --json)"
B_LOCAL_WORKSPACE_ID="$(OPEN_RESPONSE="$OPEN_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os

print(json.loads(os.environ["OPEN_RESPONSE"])["workspace_id"])
PY
)"
B_LOCAL_SURFACE_ID="$(OPEN_RESPONSE="$OPEN_RESPONSE" REMOTE_SURFACE_ID="$REMOTE_SURFACE_ID" /usr/bin/python3 - <<'PY'
import json
import os

print(json.loads(os.environ["OPEN_RESPONSE"])["surface_ids"][os.environ["REMOTE_SURFACE_ID"]])
PY
)"
B_CURRENT_AFTER="$(cli_b rpc workspace.current '{}')"
B_SELECTED_AFTER="$(CURRENT_RESPONSE="$B_CURRENT_AFTER" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["CURRENT_RESPONSE"])
result = response.get("result", response)
print(result["workspace_id"])
PY
)"
[[ "$B_SELECTED_BEFORE" == "$B_SELECTED_AFTER" ]] || {
  echo "error: hive.open stole workspace selection" >&2
  exit 1
}

B_WINDOW_RESPONSE="$(cli_b rpc window.current '{}')"
B_PRIMARY_WINDOW_ID="$(WINDOW_RESPONSE="$B_WINDOW_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["WINDOW_RESPONSE"])
result = response.get("result", response)
print(result["window_id"])
PY
)"
cli_b rpc workspace.select "{\"workspace_id\":\"$B_LOCAL_WORKSPACE_ID\",\"window_id\":\"$B_PRIMARY_WINDOW_ID\"}" \
  >"$ARTIFACT_DIR/client-select-mirror.json"

echo "==> Sending marker through the mirrored terminal"
cli_b send --workspace "$B_LOCAL_WORKSPACE_ID" --surface "$B_LOCAL_SURFACE_ID" --enter --force \
  "echo $MARKER; stty size | awk '{print \"GRID-BEFORE-$MARKER-\" \$1 \"x\" \$2}'" \
  >"$ARTIFACT_DIR/client-send-marker.txt"
wait_until "marker on host terminal" host_screen_contains "$MARKER"
wait_until "initial host grid" host_screen_matches "GRID-BEFORE-$MARKER-[0-9]+x[0-9]+"
GRID_BEFORE="$(cli_a read-screen --workspace "$A_WORKSPACE_ID" --scrollback --lines 500 \
  | grep -Eo "GRID-BEFORE-$MARKER-[0-9]+x[0-9]+" | tail -1 \
  | sed "s/GRID-BEFORE-$MARKER-//")"
[[ -n "$GRID_BEFORE" ]] || { echo "error: initial stty grid missing" >&2; exit 1; }

cli_b rpc remote.tmux.test_set_frame \
  "{\"window_id\":\"$B_PRIMARY_WINDOW_ID\",\"width\":520,\"height\":320,\"interactive\":true}" \
  >"$ARTIFACT_DIR/client-resize.json"
cli_b send --workspace "$B_LOCAL_WORKSPACE_ID" --surface "$B_LOCAL_SURFACE_ID" --enter --force \
  "sleep 2; stty size | awk '{print \"GRID-AFTER-$MARKER-\" \$1 \"x\" \$2}'" \
  >"$ARTIFACT_DIR/client-send-resize-marker.txt"
wait_until "resized host grid" host_screen_matches "GRID-AFTER-$MARKER-[0-9]+x[0-9]+"
GRID_AFTER="$(cli_a read-screen --workspace "$A_WORKSPACE_ID" --scrollback --lines 500 \
  | grep -Eo "GRID-AFTER-$MARKER-[0-9]+x[0-9]+" | tail -1 \
  | sed "s/GRID-AFTER-$MARKER-//")"
[[ -n "$GRID_AFTER" && "$GRID_AFTER" != "$GRID_BEFORE" ]] || {
  echo "error: client resize did not change host PTY grid: before=$GRID_BEFORE after=$GRID_AFTER" >&2
  exit 1
}

echo "==> Creating a host terminal from the Hive mirror"
cli_b rpc surface.create \
  "{\"workspace_id\":\"$B_LOCAL_WORKSPACE_ID\",\"type\":\"terminal\",\"focus\":false}" \
  >"$ARTIFACT_DIR/client-create-remote-terminal.json"
wait_until "new terminal on host" host_has_two_surfaces
wait_until "new terminal in Hive snapshot" client_has_two_remote_terminals

SECOND_WINDOW_RESPONSE="$(cli_b rpc window.create '{}')"
B_SECOND_WINDOW_ID="$(WINDOW_RESPONSE="$SECOND_WINDOW_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["WINDOW_RESPONSE"])
result = response.get("result", response)
print(result["window_id"])
PY
)"
cli_b hive open "$REMOTE_WORKSPACE_ID" --window "$B_SECOND_WINDOW_ID" --json \
  >"$ARTIFACT_DIR/client-open-second-window.json"
wait_until "one remote registration shared by two local windows" single_shared_attachment_ready

WINDOWS_BEFORE_RESTART="$(cli_b rpc window.list '{}')"
WINDOW_COUNT_BEFORE="$(WINDOW_RESPONSE="$WINDOWS_BEFORE_RESTART" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["WINDOW_RESPONSE"])
result = response.get("result", response)
print(len(result["windows"]))
PY
)"

echo "==> Restarting host and reconnecting through hive.status"
stop_a
sleep 2
launch_a
wait_until "Hive reconnect after host restart" client_connected
wait_until "unchanged client window count after status reconnect" client_window_count_unchanged

echo "==> Removing and remotely revoking the Hive pairing"
cli_b hive remove "$PAIRING_ID" --json >"$ARTIFACT_DIR/client-remove.json"
wait_until "host pairing revocation" host_pairing_revoked
cli_b hive list --json >"$ARTIFACT_DIR/client-list-after-remove.json"
LIST_PATH="$ARTIFACT_DIR/client-list-after-remove.json" /usr/bin/python3 - <<'PY'
import json
import os

with open(os.environ["LIST_PATH"]) as file:
    status = json.load(file)
if status.get("has_pairing") or status.get("paired_macs"):
    raise SystemExit("client retained removed pairing")
PY

ELAPSED=$(( $(date +%s) - RUN_STARTED ))
REPORT_PATH="$ARTIFACT_DIR/report.json"
REPORT_PATH="$REPORT_PATH" TAG="$TAG" MARKER="$MARKER" \
A_WORKSPACE_ID="$A_WORKSPACE_ID" REMOTE_WORKSPACE_ID="$REMOTE_WORKSPACE_ID" \
GRID_BEFORE="$GRID_BEFORE" GRID_AFTER="$GRID_AFTER" ELAPSED="$ELAPSED" \
  /usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

report = {
    "schema_version": 1,
    "result": "passed",
    "tag": os.environ["TAG"],
    "marker": os.environ["MARKER"],
    "host_workspace_id": os.environ["A_WORKSPACE_ID"],
    "remote_workspace_id": os.environ["REMOTE_WORKSPACE_ID"],
    "marker_round_trip": True,
    "host_grid_before": os.environ["GRID_BEFORE"],
    "host_grid_after": os.environ["GRID_AFTER"],
    "remote_terminal_created": True,
    "two_window_local_mounts": 2,
    "remote_output_registrations": 1,
    "host_restart_reconnected_via_status": True,
    "status_window_count_unchanged": True,
    "pairing_revoked": True,
    "elapsed_seconds": int(os.environ["ELAPSED"]),
}
Path(os.environ["REPORT_PATH"]).write_text(json.dumps(report, indent=2) + "\n")
PY

echo "Mac-to-Mac Hive E2E passed in ${ELAPSED}s: $REPORT_PATH"
