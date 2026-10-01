#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/e2e/mobile-mac-e2e.sh [--tag TAG] [--artifact-dir DIR]
       [--derived-data DIR] [--timeout-seconds N]

Runs the real iOS Simulator -> tagged Mac DeviceLink journey. The script owns
an isolated simulator, builds and launches only a tagged Debug Mac app from this
checkout, creates a workspace through that app's bundled CLI, and coordinates
the focused cmuxUITests/testDeviceLinkMacRoundTripE2E XCUITest.
EOF
}

TAG="e2e-mobile"
ARTIFACT_DIR=""
DERIVED_DATA_ROOT="${CMUX_E2E_DERIVED_DATA_ROOT:-$HOME/src/dd-cmux-remote-nightly/phase3a}"
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

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; exit 2; }
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: --timeout-seconds must be a positive integer" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[[ "$REPO_ROOT" != "/" && "$REPO_ROOT" != "$HOME" ]] || {
  echo "error: refusing to run with repository cwd $REPO_ROOT" >&2
  exit 2
}

# shellcheck source=scripts/fork-identity.env
source "$REPO_ROOT/scripts/fork-identity.env"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$REPO_ROOT/scripts/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$TAG"
SLUG="$(cmux_attach__slug "$TAG")"
BUNDLE_SEG="$(cmux_attach__bundle_seg "$TAG")"
MAC_BUNDLE_ID="${CMUX_FORK_BUNDLE_ID}.debug.${BUNDLE_SEG}"
IOS_BUNDLE_ID="${CMUX_FORK_BUNDLE_ID}.ios"
SOCKET_PATH="$(cmux_attach_socket_path "$TAG")"
MAC_DERIVED_DATA="$DERIVED_DATA_ROOT/mac"
IOS_DERIVED_DATA="$DERIVED_DATA_ROOT/ios"

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="${RUNNER_TEMP:-$HOME/src/task-data/cmux-remote-nightly}/mobile-mac-e2e-${SLUG}-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$ARTIFACT_DIR" "$MAC_DERIVED_DATA" "$IOS_DERIVED_DATA"
umask 077

export DEVELOPER_DIR="/Applications/Xcode-26.6.app/Contents/Developer"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: required Xcode not found at $DEVELOPER_DIR" >&2
  exit 1
fi

# Never inherit a caller's cmux routing into app tests or tagged CLI calls.
unset CMUX_SOCKET CMUX_SOCKET_PATH CMUX_SOCKET_PASSWORD CMUX_BUNDLED_CLI_PATH
unset CMUX_BUNDLE_ID CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID
unset CMUX_TERMINAL_LIFECYCLE_ID CMUXD_UNIX_PATH CMUX_DEBUG_LOG
unset CMUX_PORT CMUX_PORT_END CMUX_PORT_RANGE CMUX_SHELL_INTEGRATION
unset CMUX_SHELL_INTEGRATION_DIR CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION

SIMULATOR_ID=""
MAC_PID=""
XCODEBUILD_PID=""
XCODEBUILD_RESULT=""
RUN_STARTED="$(date +%s)"

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [[ -n "$XCODEBUILD_PID" ]] && kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
    kill "$XCODEBUILD_PID" 2>/dev/null || true
    wait "$XCODEBUILD_PID" 2>/dev/null || true
  fi
  if [[ -n "$MAC_PID" ]] && kill -0 "$MAC_PID" 2>/dev/null; then
    kill "$MAC_PID" 2>/dev/null || true
    wait "$MAC_PID" 2>/dev/null || true
  fi
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl terminate "$SIMULATOR_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  if [[ -S "$SOCKET_PATH" && -z "$(lsof -t "$SOCKET_PATH" 2>/dev/null || true)" ]]; then
    rm -f -- "$SOCKET_PATH"
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

wait_for_phone_screen() {
  local description="$1"
  local needle="$2"
  local match_mode="${3:-fixed}"
  local started grace_attempt
  started="$(date +%s)"
  while (( $(date +%s) - started < TIMEOUT_SECONDS )); do
    if phone_screen_matches "$needle" "$match_mode"; then
      return 0
    fi
    if [[ -n "$XCODEBUILD_PID" ]] && ! kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
      set +e
      wait "$XCODEBUILD_PID"
      XCODEBUILD_RESULT=$?
      set -e
      XCODEBUILD_PID=""
      if [[ "$XCODEBUILD_RESULT" -eq 0 ]]; then
        # The focused test can finish just after its final phone-side
        # assertion while the Mac socket still has one render update queued.
        for grace_attempt in 1 2 3 4 5; do
          if phone_screen_matches "$needle" "$match_mode"; then
            return 0
          fi
          sleep 1
        done
      fi
      tail -n 120 "$ARTIFACT_DIR/ios-ui-test.log" >&2
      echo "error: iOS UI test exited ($XCODEBUILD_RESULT) before $description" >&2
      return 1
    fi
    sleep 1
  done
  echo "error: timed out waiting for $description" >&2
  return 1
}

phone_screen_matches() {
  local needle="$1"
  local match_mode="$2"
  case "$match_mode" in
    fixed) screen_contains "$needle" ;;
    regex) screen_matches "$needle" ;;
    any-fixed) any_workspace_screen_contains "$needle" ;;
    *) echo "error: unknown phone screen match mode: $match_mode" >&2; return 2 ;;
  esac
}

wait_for_socket() {
  [[ -S "$SOCKET_PATH" ]]
}

cli() {
  env \
    -u CMUX_SOCKET \
    -u CMUX_SOCKET_PASSWORD \
    -u CMUX_WORKSPACE_ID \
    -u CMUX_SURFACE_ID \
    -u CMUX_TAB_ID \
    -u CMUX_PANEL_ID \
    CMUX_SOCKET_PATH="$SOCKET_PATH" \
    CMUX_BUNDLE_ID="$MAC_BUNDLE_ID" \
    CMUX_BUNDLED_CLI_PATH="$MAC_CLI" \
    "$MAC_CLI" "$@"
}

screen_contains() {
  local needle="$1"
  cli read-screen --workspace "$WORKSPACE_ID" --scrollback --lines 500 2>/dev/null \
    | grep -Fq -- "$needle"
}

screen_matches() {
  local expression="$1"
  cli read-screen --workspace "$WORKSPACE_ID" --scrollback --lines 500 2>/dev/null \
    | grep -Eq -- "$expression"
}

any_workspace_screen_contains() {
  local needle="$1"
  local workspace_ref
  while IFS= read -r workspace_ref; do
    if cli read-screen --workspace "$workspace_ref" --scrollback --lines 500 2>/dev/null \
      | grep -Fq -- "$needle"; then
      return 0
    fi
  done < <(cli list-workspaces 2>/dev/null | grep -Eo 'workspace:[0-9]+')
  return 1
}

pairing_management_ready() {
  cli rpc mobile.pairing.device.list '{}' \
    >"$ARTIFACT_DIR/pairing-readiness.json" \
    2>>"$ARTIFACT_DIR/pairing-readiness.log"
}

host_ui_ready() {
  cli list-workspaces \
    >"$ARTIFACT_DIR/host-ui-readiness.txt" \
    2>>"$ARTIFACT_DIR/host-ui-readiness.log"
}

launch_mac() {
  local executable cmuxd_socket debug_log
  executable="$MAC_APP/Contents/MacOS/$CMUX_FORK_APP_NAME DEV"
  cmuxd_socket="$HOME/Library/Application Support/cmux/cmuxd-dev-${SLUG}.sock"
  debug_log="$ARTIFACT_DIR/mac-debug.log"
  [[ -x "$executable" ]] || { echo "error: tagged Mac executable missing: $executable" >&2; return 1; }
  (
    cd "$REPO_ROOT"
    exec env \
      CMUX_FORK_BUNDLE_ID="$MAC_BUNDLE_ID" \
      CMUXD_UNIX_PATH="$cmuxd_socket" \
      CMUX_SOCKET_PATH="$SOCKET_PATH" \
      CMUX_DEBUG_LOG="$debug_log" \
      CMUX_TAG="$SLUG" \
      CMUX_AUTH_CALLBACK_SCHEME="cmux-dev-$SLUG" \
      CMUX_SOCKET_ENABLE=1 \
      CMUX_SOCKET_MODE=allowAll \
      CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 \
      CMUX_E2E_DEVICELINK_STATE_DIR="$ARTIFACT_DIR/mac-devicelink-state" \
      CMUXTERM_REPO_ROOT="$REPO_ROOT" \
      CMUX_BUNDLED_CLI_PATH="$MAC_CLI" \
      CMUX_SHELL_INTEGRATION_DIR="$MAC_APP/Contents/Resources/shell-integration" \
      "$executable" >>"$ARTIFACT_DIR/mac-stdio.log" 2>&1
  ) &
  MAC_PID=$!
  wait_until "tagged Mac debug socket" wait_for_socket
  wait_until "tagged Mac CLI ping" cli rpc system.ping '{}'
}

stop_mac() {
  [[ -n "$MAC_PID" ]] || return 0
  kill -KILL "$MAC_PID" 2>/dev/null || true
  wait "$MAC_PID" 2>/dev/null || true
  MAC_PID=""
  cmux_attach_remove_stale_socket "$TAG"
  [[ ! -S "$SOCKET_PATH" ]]
}

latest_simulator_spec() {
  /usr/bin/python3 - <<'PY'
import json
import subprocess

def data(kind):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", kind, "-j"]))

runtimes = [
    runtime for runtime in data("runtimes").get("runtimes", [])
    if runtime.get("isAvailable", True)
    and runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
]
if not runtimes:
    raise SystemExit("No available iOS Simulator runtime")

def version(runtime):
    return tuple(int(part) for part in runtime.get("version", "0").split("."))

runtime = max(runtimes, key=version)
device_types = [
    device for device in data("devicetypes").get("devicetypes", [])
    if device.get("name", "").startswith("iPhone")
]
preferred = ["iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16"]
device = next((item for name in preferred for item in device_types if item.get("name") == name), None)
if device is None:
    device = device_types[-1]
print(runtime["identifier"])
print(device["identifier"])
PY
}

echo "==> Building tagged Mac debug app: $TAG"
(
  cd "$REPO_ROOT"
  CMUX_SKIP_ZIG_BUILD=1 CMUX_RELOAD_NO_GLOBAL_CLI_LINKS=1 \
    ./scripts/reload.sh --tag "$TAG" --derived-data "$MAC_DERIVED_DATA" \
      --no-global-cli-links
) 2>&1 | tee "$ARTIFACT_DIR/mac-build.log"

MAC_APP="$MAC_DERIVED_DATA/Build/Products/Debug/$CMUX_FORK_APP_NAME DEV $SLUG.app"
MAC_CLI="$MAC_APP/Contents/Resources/bin/cmux"
[[ -d "$MAC_APP" && -x "$MAC_CLI" ]] || {
  echo "error: tagged Mac build products are missing" >&2
  exit 1
}

cmux_attach_enable_pairing_host "$TAG"
launch_mac
wait_until "tagged Mac main-actor command lane" host_ui_ready

WORKSPACE_NAME="mobile-e2e-$SLUG"
WORKSPACE_RESPONSE="$(cli rpc workspace.create "{\"cwd\":\"$REPO_ROOT\",\"title\":\"$WORKSPACE_NAME\",\"focus\":true}")"
WORKSPACE_ID="$(WORKSPACE_RESPONSE="$WORKSPACE_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["WORKSPACE_RESPONSE"])
result = response.get("result", response)
workspace_id = result.get("workspace_id") or result.get("workspace_ref")
if not workspace_id:
    raise SystemExit("workspace.create response did not include workspace_id")
print(workspace_id)
PY
)"

# The socket is available before the DeviceLink coordinator's cold-start load
# has necessarily completed. Wait for the local management verb itself rather
# than racing code creation against that actor initialization.
wait_until "DeviceLink pairing management readiness" pairing_management_ready
PAIRING_RESPONSE="$(cli rpc mobile.pairing.code.create '{"ttl_seconds":600}')"
PAIRING_URL="$(PAIRING_RESPONSE="$PAIRING_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os
import urllib.parse

response = json.loads(os.environ["PAIRING_RESPONSE"])
result = response.get("result", response)
url = result["pairing_url"]
query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
if query.get("v") != ["3"] or not query.get("t") or not query.get("r"):
    raise SystemExit("mobile.pairing.code.create returned an invalid v3 URL")
print(url)
PY
)"

SIMULATOR_SPEC="$(latest_simulator_spec)"
SIMULATOR_RUNTIME="$(printf '%s\n' "$SIMULATOR_SPEC" | sed -n '1p')"
SIMULATOR_DEVICE_TYPE="$(printf '%s\n' "$SIMULATOR_SPEC" | sed -n '2p')"
SIMULATOR_NAME="cmux-e2e-$SLUG"
SIMULATOR_ID="$(xcrun simctl create "$SIMULATOR_NAME" "$SIMULATOR_DEVICE_TYPE" "$SIMULATOR_RUNTIME")"
echo "==> Booting private simulator: $SIMULATOR_NAME ($SIMULATOR_ID)"
xcrun simctl boot "$SIMULATOR_ID" >/dev/null
xcrun simctl bootstatus "$SIMULATOR_ID" -b

echo "==> Building focused iOS UI test"
(
  cd "$REPO_ROOT"
  CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
    -workspace ios/cmux.xcworkspace \
    -scheme cmux-ios \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    CMUX_DEV_TAG="$SLUG" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=- \
    -only-testing:cmuxUITests/cmuxUITests/testDeviceLinkMacRoundTripE2E \
    build-for-testing
) >"$ARTIFACT_DIR/ios-build.log" 2>&1

XCTESTRUN_FILE="$(find "$IOS_DERIVED_DATA/Build/Products" -maxdepth 1 \
  -name 'cmux-ios_*.xctestrun' -print -quit)"
[[ -f "$XCTESTRUN_FILE" ]] || {
  echo "error: build-for-testing did not produce an xctestrun file" >&2
  exit 1
}

IOS_APP="$IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/cmux.app"
[[ -d "$IOS_APP" ]] || { echo "error: iOS app missing at $IOS_APP" >&2; exit 1; }
xcrun simctl install "$SIMULATOR_ID" "$IOS_APP"

MARKER="MARKER-$(jot -r 1 100000 999999)-$(date +%s)"

# Xcode deliberately sanitizes the UI-test runner environment. Put the
# one-run coordination values into the generated test plan rather than relying
# on variables inherited by xcodebuild.
UI_TEST_TARGET_INDEX="$(XCTESTRUN_FILE="$XCTESTRUN_FILE" /usr/bin/python3 - <<'PY'
import os
import plistlib

with open(os.environ["XCTESTRUN_FILE"], "rb") as file:
    run = plistlib.load(file)
targets = run["TestConfigurations"][0]["TestTargets"]
for index, target in enumerate(targets):
    if target.get("BlueprintName") == "cmuxUITests":
        print(index)
        break
else:
    raise SystemExit("cmuxUITests is missing from the generated xctestrun file")
PY
)"
XCTESTRUN_ENV_PREFIX="TestConfigurations.0.TestTargets.${UI_TEST_TARGET_INDEX}.EnvironmentVariables"
plutil -replace "$XCTESTRUN_ENV_PREFIX.CMUX_E2E_PAIRING_URL" \
  -string "$PAIRING_URL" "$XCTESTRUN_FILE"
plutil -replace "$XCTESTRUN_ENV_PREFIX.CMUX_E2E_WORKSPACE_ID" \
  -string "$WORKSPACE_ID" "$XCTESTRUN_FILE"
plutil -replace "$XCTESTRUN_ENV_PREFIX.CMUX_E2E_MARKER" \
  -string "$MARKER" "$XCTESTRUN_FILE"

echo "==> Running real DeviceLink UI journey: $MARKER"
(
  cd "$REPO_ROOT"
  xcodebuild \
      -xctestrun "$XCTESTRUN_FILE" \
      -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
      -only-testing:cmuxUITests/cmuxUITests/testDeviceLinkMacRoundTripE2E \
      test-without-building
) >"$ARTIFACT_DIR/ios-ui-test.log" 2>&1 &
XCODEBUILD_PID=$!

wait_for_phone_screen "phone marker on the Mac" "$MARKER"
wait_for_phone_screen "portrait stty size" 'SIZE-P-[0-9]+x[0-9]+' regex
wait_for_phone_screen "landscape stty size" 'SIZE-L-[0-9]+x[0-9]+' regex

SIZE_TEXT="$(cli read-screen --workspace "$WORKSPACE_ID" --scrollback --lines 500)"
PORTRAIT_SIZE="$(printf '%s\n' "$SIZE_TEXT" | grep -Eo 'SIZE-P-[0-9]+x[0-9]+' | tail -1 | cut -d- -f3 || true)"
LANDSCAPE_SIZE="$(printf '%s\n' "$SIZE_TEXT" | grep -Eo 'SIZE-L-[0-9]+x[0-9]+' | tail -1 | cut -d- -f3 || true)"
[[ -n "$PORTRAIT_SIZE" && -n "$LANDSCAPE_SIZE" && "$PORTRAIT_SIZE" != "$LANDSCAPE_SIZE" ]] || {
  echo "error: phone rotation did not change Mac PTY size: portrait=$PORTRAIT_SIZE landscape=$LANDSCAPE_SIZE" >&2
  exit 1
}

wait_for_phone_screen "phone resize barrier" "RESIZE-READY-$MARKER"
WINDOW_RESPONSE="$(cli rpc window.list '{}')"
WINDOW_ID="$(WINDOW_RESPONSE="$WINDOW_RESPONSE" /usr/bin/python3 - <<'PY'
import json
import os

response = json.loads(os.environ["WINDOW_RESPONSE"])
result = response.get("result", response)
windows = result.get("windows", result if isinstance(result, list) else [])
if not windows:
    raise SystemExit("window.list returned no windows")
window_id = windows[0].get("id") or windows[0].get("window_id")
if not window_id:
    raise SystemExit("window.list returned no window id")
print(window_id)
PY
)"
cli rpc remote.tmux.test_set_frame \
  "{\"window_id\":\"$WINDOW_ID\",\"width\":560,\"height\":340}" \
  >"$ARTIFACT_DIR/mac-resize.json"
cli send --workspace "$WORKSPACE_ID" --enter --force \
  "sleep 1; echo RESIZE-APPLIED-$MARKER" \
  >"$ARTIFACT_DIR/mac-resize-terminal-signal.txt"
wait_for_phone_screen "post-resize stty size" 'SIZE-MAC-[0-9]+x[0-9]+' regex

wait_for_phone_screen "foreground marker" "$MARKER-FOREGROUND"
wait_for_phone_screen "host restart barrier" "RESTART-READY-$MARKER"
echo "==> Killing and restarting tagged Mac host"
stop_mac
# Keep the transport unavailable long enough for the iOS status pill to expose
# the disconnect; this is the deliberate outage under test, not a settle wait.
sleep 3
launch_mac
wait_for_phone_screen "reconnected phone marker" "$MARKER-RECONNECTED" any-fixed

if [[ -n "$XCODEBUILD_PID" ]]; then
  set +e
  wait "$XCODEBUILD_PID"
  XCODEBUILD_RESULT=$?
  set -e
  XCODEBUILD_PID=""
fi
if [[ "$XCODEBUILD_RESULT" -ne 0 ]]; then
  tail -n 120 "$ARTIFACT_DIR/ios-ui-test.log" >&2
  exit "$XCODEBUILD_RESULT"
fi
if ! grep -Fq "testDeviceLinkMacRoundTripE2E]' passed" "$ARTIFACT_DIR/ios-ui-test.log"; then
  tail -n 120 "$ARTIFACT_DIR/ios-ui-test.log" >&2
  echo "error: focused DeviceLink UI test did not report a passing result" >&2
  exit 1
fi

ELAPSED=$(( $(date +%s) - RUN_STARTED ))
REPORT_PATH="$ARTIFACT_DIR/report.json"
TAG="$TAG" SLUG="$SLUG" MARKER="$MARKER" WORKSPACE_ID="$WORKSPACE_ID" \
SIMULATOR_ID="$SIMULATOR_ID" PORTRAIT_SIZE="$PORTRAIT_SIZE" \
LANDSCAPE_SIZE="$LANDSCAPE_SIZE" ELAPSED="$ELAPSED" REPORT_PATH="$REPORT_PATH" \
/usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

report = {
    "schema_version": 1,
    "result": "passed",
    "tag": os.environ["TAG"],
    "tag_slug": os.environ["SLUG"],
    "marker": os.environ["MARKER"],
    "workspace_id": os.environ["WORKSPACE_ID"],
    "simulator_id": os.environ["SIMULATOR_ID"],
    "portrait_stty_size": os.environ["PORTRAIT_SIZE"],
    "landscape_stty_size": os.environ["LANDSCAPE_SIZE"],
    "host_resize_phone_bottom_fit": True,
    "background_foreground_marker": True,
    "host_restart_reconnected": True,
    "elapsed_seconds": int(os.environ["ELAPSED"]),
}
Path(os.environ["REPORT_PATH"]).write_text(json.dumps(report, indent=2) + "\n")
PY

echo "Mobile -> Mac DeviceLink E2E passed in ${ELAPSED}s: $REPORT_PATH"
