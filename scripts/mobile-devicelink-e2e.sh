#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/mobile-devicelink-e2e.sh --tag TAG [--simulator-id UDID|--simulator NAME]
       scripts/mobile-devicelink-e2e.sh --tag TAG --device [--device-id ID]
       [--app PATH] [--artifact-dir DIR] [--timeout-seconds N] [--reuse-install]

Runs account-free DeviceLink proof against the exact tagged Mac:
  1. cold install (unless --reuse-install)
  2. mint/inject a v3 pairing code and assert persistence + workspace sync
  3. terminate and cold-relaunch without a code or Stack credentials
  4. assert the stored device identity reconnects and workspace sync resumes

The report contains no pairing URL, enrollment ticket, or Stack credential.
Physical-device mode uses devicectl for install, launch, debug-log copy, and a
screenshot. Unlock the iPhone and keep it reachable over USB/local network.
EOF
}

TAG=""
TARGET="simulator"
SIMULATOR_ID=""
SIMULATOR_NAME="iPhone 17"
DEVICE_ID=""
APP_PATH=""
ARTIFACT_DIR=""
TIMEOUT_SECONDS="150"
REUSE_INSTALL="0"
PAIR_STABILITY_SECONDS="${CMUX_DEVICELINK_PAIR_STABILITY_SECONDS:-5}"
RECONNECT_STABILITY_SECONDS="${CMUX_DEVICELINK_RECONNECT_STABILITY_SECONDS:-15}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --simulator-id) TARGET="simulator"; SIMULATOR_ID="${2:-}"; shift 2 ;;
    --simulator) TARGET="simulator"; SIMULATOR_NAME="${2:-}"; shift 2 ;;
    --device) TARGET="device"; shift ;;
    --device-id) TARGET="device"; DEVICE_ID="${2:-}"; shift 2 ;;
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --reuse-install) REUSE_INSTALL="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "error: --timeout-seconds must be positive" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$TAG"
SLUG="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="${CMUX_FORK_BUNDLE_ID}.ios.$SLUG"

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="${TMPDIR:-/tmp}/cmux-devicelink-e2e-$SLUG-$(date +%Y%m%d-%H%M%S)"
fi
umask 077
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"

if [[ "$TARGET" == "simulator" ]]; then
  if [[ -z "$SIMULATOR_ID" ]]; then
    SIMULATOR_ID="$(SIMULATOR_NAME="$SIMULATOR_NAME" /usr/bin/python3 - <<'PY'
import json
import os
import subprocess

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "-j"]))
for devices in data.get("devices", {}).values():
    for device in devices:
        if device.get("name") == os.environ["SIMULATOR_NAME"]:
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
PY
    )" || { echo "error: simulator '$SIMULATOR_NAME' is not booted" >&2; exit 1; }
  fi
  TARGET_ID="$SIMULATOR_ID"
  [[ -n "$APP_PATH" ]] || APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$SLUG/Build/Products/Debug-iphonesimulator/cmux.app"
else
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
      | awk '/iPhone/ && !/unavailable/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-Fa-f-]{36}$/){print $i; exit}}')"
  fi
  [[ -n "$DEVICE_ID" ]] || { echo "error: no reachable iPhone; pass --device-id" >&2; exit 1; }
  TARGET_ID="$DEVICE_ID"
  [[ -n "$APP_PATH" ]] || APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$SLUG/Build/Products/Debug-iphoneos/cmux.app"
fi

if [[ "$REUSE_INSTALL" != "1" ]]; then
  [[ -d "$APP_PATH" ]] || { echo "error: app not found at $APP_PATH; build it with ios/scripts/reload.sh --tag $TAG --no-launch" >&2; exit 1; }
  if [[ "$TARGET" == "simulator" ]]; then
    xcrun simctl uninstall "$TARGET_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$TARGET_ID" "$APP_PATH"
  else
    xcrun devicectl device uninstall app --device "$TARGET_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun devicectl device install app --device "$TARGET_ID" "$APP_PATH" \
      --json-output "$ARTIFACT_DIR/install.json" --log-output "$ARTIFACT_DIR/install.log"
  fi
fi

collect_log() {
  local destination="$1" container
  rm -f -- "$destination"
  if [[ "$TARGET" == "simulator" ]]; then
    container="$(xcrun simctl get_app_container "$TARGET_ID" "$BUNDLE_ID" data 2>/dev/null || true)"
    [[ -n "$container" && -f "$container/Library/Application Support/cmux-debug.log" ]] || return 1
    cp "$container/Library/Application Support/cmux-debug.log" "$destination"
  else
    xcrun devicectl device copy from --device "$TARGET_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Library/Application Support/cmux-debug.log" \
      --destination "$destination" --quiet >/dev/null 2>&1
  fi
}

wait_for_markers() {
  local destination="$1" forbidden="$2"; shift 2
  local started marker missing
  started="$(date +%s)"
  while (( $(date +%s) - started < TIMEOUT_SECONDS )); do
    if collect_log "$destination"; then
      # MobileDebugLog rotates the active file on every process start. Requiring
      # the phase-one marker to be absent prevents a fast first poll from
      # accepting the previous process's file before the cold launch rotates it.
      if [[ -n "$forbidden" ]] && grep -Eq "$forbidden" "$destination"; then
        sleep 2
        continue
      fi
      missing="0"
      for marker in "$@"; do
        if ! grep -Eq "$marker" "$destination"; then
          missing="1"
          break
        fi
      done
      [[ "$missing" == "1" ]] || return 0
    fi
    sleep 2
  done
  echo "error: timed out waiting for DeviceLink evidence in $destination" >&2
  if [[ -n "$forbidden" ]] && grep -Eq "$forbidden" "$destination" 2>/dev/null; then
    echo "  stale phase-one log still active: $forbidden" >&2
  fi
  for marker in "$@"; do
    grep -Eq "$marker" "$destination" 2>/dev/null || echo "  missing: $marker" >&2
  done
  return 1
}

wait_for_stable_markers() {
  local destination="$1" forbidden="$2" stable_seconds="$3"
  shift 3
  local started now marker missing last_subscribe last_stream_end
  local candidate_subscribe="" candidate_started="0"
  started="$(date +%s)"
  while (( $(date +%s) - started < TIMEOUT_SECONDS )); do
    if collect_log "$destination"; then
      if [[ -n "$forbidden" ]] && grep -Eq "$forbidden" "$destination"; then
        candidate_subscribe=""
        candidate_started="0"
        sleep 2
        continue
      fi
      missing="0"
      for marker in "$@"; do
        if ! grep -Eq "$marker" "$destination"; then
          missing="1"
          break
        fi
      done
      if [[ "$missing" == "0" ]]; then
        last_subscribe="$(grep -nE 'sync\.subscribe_ok topics=' "$destination" \
          | tail -1 | cut -d: -f1)"
        last_stream_end="$(grep -nE 'sync\.stream_ended' "$destination" \
          | tail -1 | cut -d: -f1 || true)"
        [[ -n "$last_stream_end" ]] || last_stream_end="0"
        if (( last_subscribe > last_stream_end )); then
          now="$(date +%s)"
          if [[ "$candidate_subscribe" != "$last_subscribe" ]]; then
            candidate_subscribe="$last_subscribe"
            candidate_started="$now"
          elif (( now - candidate_started >= stable_seconds )); then
            return 0
          fi
        else
          candidate_subscribe=""
          candidate_started="0"
        fi
      fi
    fi
    sleep 2
  done
  echo "error: timed out waiting for ${stable_seconds}s of stable DeviceLink evidence in $destination" >&2
  for marker in "$@"; do
    grep -Eq "$marker" "$destination" 2>/dev/null || echo "  missing: $marker" >&2
  done
  return 1
}

launch_args=(--tag "$TAG" --attach --ensure-mac)
if [[ "$TARGET" == "simulator" ]]; then
  launch_args+=(--simulator-id "$TARGET_ID" --detach)
else
  launch_args+=(--device --device-id "$TARGET_ID")
fi
"$SCRIPT_DIR/mobile-dev-launch.sh" "${launch_args[@]}" \
  >"$ARTIFACT_DIR/pair-launch.log" 2>&1

PAIR_LOG="$ARTIFACT_DIR/pairing.cmux-debug.log"
wait_for_stable_markers "$PAIR_LOG" '' "$PAIR_STABILITY_SECONDS" \
  'devicelink .*pairing persisted=true' \
  'devicelink .*post-pairing dial connected=true' \
  'sync\.subscribe_ok topics=[1-9][0-9]*'

if [[ "$TARGET" == "simulator" ]]; then
  xcrun simctl io "$TARGET_ID" screenshot --type=png "$ARTIFACT_DIR/pairing.png" >/dev/null
  if command -v xcodebuildmcp >/dev/null 2>&1; then
    xcodebuildmcp ui-automation snapshot-ui --simulator-id "$TARGET_ID" --output json \
      >"$ARTIFACT_DIR/pairing-ui.json" 2>&1 || true
  fi
else
  xcrun devicectl device capture screenshot --device "$TARGET_ID" \
    --destination "$ARTIFACT_DIR/pairing.png" >/dev/null 2>&1 || true
fi

# No URL and no Stack environment on this second launch. Any connection now
# must come from the key and routes persisted by DeviceLink during phase one.
relaunch_args=(--tag "$TAG" --no-attach)
if [[ "$TARGET" == "simulator" ]]; then
  relaunch_args+=(--simulator-id "$TARGET_ID" --detach)
else
  relaunch_args+=(--device --device-id "$TARGET_ID")
fi
"$SCRIPT_DIR/mobile-dev-launch.sh" "${relaunch_args[@]}" \
  >"$ARTIFACT_DIR/relaunch.log" 2>&1

RECONNECT_LOG="$ARTIFACT_DIR/reconnect.cmux-debug.log"
wait_for_stable_markers "$RECONNECT_LOG" 'pairing persisted=true' "$RECONNECT_STABILITY_SECONDS" \
  'reconnect gate .*stack=false .*pairedDevice=true' \
  'dial decision .*credential=true canConnect=true' \
  'sync\.subscribe_ok topics=[1-9][0-9]*' \
  'changes\.summary ok requested=[1-9][0-9]*'

if [[ "$TARGET" == "simulator" ]]; then
  xcrun simctl io "$TARGET_ID" screenshot --type=png "$ARTIFACT_DIR/reconnect.png" >/dev/null
  if command -v xcodebuildmcp >/dev/null 2>&1; then
    xcodebuildmcp ui-automation snapshot-ui --simulator-id "$TARGET_ID" --output json \
      >"$ARTIFACT_DIR/reconnect-ui.json" 2>&1 || true
  fi
else
  xcrun devicectl device capture screenshot --device "$TARGET_ID" \
    --destination "$ARTIFACT_DIR/reconnect.png" >/dev/null 2>&1 || true
fi

# The transport markers above are necessary but not sufficient: a reconnect can
# succeed underneath the first-run tour. On Simulator, also inspect the app's
# durable onboarding state so a log-only pass cannot hide the wrong UI again.
ONBOARDING_COMPLETE="not_machine_readable"
if [[ "$TARGET" == "simulator" ]]; then
  onboarding_container="$(xcrun simctl get_app_container "$TARGET_ID" "$BUNDLE_ID" data)"
  onboarding_preferences="$onboarding_container/Library/Preferences/$BUNDLE_ID.plist"
  onboarding_started="$(date +%s)"
  while (( $(date +%s) - onboarding_started < 15 )); do
    if ONBOARDING_PREFERENCES="$onboarding_preferences" /usr/bin/python3 - <<'PY'
import os
import plistlib
from pathlib import Path

path = Path(os.environ["ONBOARDING_PREFERENCES"])
if not path.is_file():
    raise SystemExit(1)
with path.open("rb") as stream:
    preferences = plistlib.load(stream)
raise SystemExit(
    preferences.get("dev.cmux.mobile.onboarding.redesign.progress.v1") != "complete"
)
PY
    then
      ONBOARDING_COMPLETE="true"
      break
    fi
    sleep 1
  done
  if [[ "$ONBOARDING_COMPLETE" != "true" ]]; then
    echo "error: DeviceLink reconnected, but durable onboarding is not complete" >&2
    exit 1
  fi
fi

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
REPORT_PATH="$ARTIFACT_DIR/report.json"
TARGET="$TARGET" TARGET_ID="$TARGET_ID" TAG="$TAG" BUNDLE_ID="$BUNDLE_ID" \
GIT_SHA="$GIT_SHA" REUSE_INSTALL="$REUSE_INSTALL" REPORT_PATH="$REPORT_PATH" \
ONBOARDING_COMPLETE="$ONBOARDING_COMPLETE" \
PAIR_STABILITY_SECONDS="$PAIR_STABILITY_SECONDS" \
RECONNECT_STABILITY_SECONDS="$RECONNECT_STABILITY_SECONDS" \
/usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

report = {
    "schema_version": 1,
    "result": "passed",
    "target": os.environ["TARGET"],
    "target_id": os.environ["TARGET_ID"],
    "tag": os.environ["TAG"],
    "bundle_id": os.environ["BUNDLE_ID"],
    "git_sha": os.environ["GIT_SHA"],
    "cold_install": os.environ["REUSE_INSTALL"] != "1",
    "pairing": {
        "mode": "devicelink_v3",
        "transport": "tailscale" if os.environ["TARGET"] == "device" else "debug_loopback_or_tailscale",
        "stack_credentials_injected": False,
        "persisted": True,
        "connected": True,
        "workspace_sync": True,
        "stable_seconds": int(os.environ["PAIR_STABILITY_SECONDS"]),
    },
    "cold_relaunch": {
        "pairing_url_injected": False,
        "stack_credentials_injected": False,
        "paired_identity_adopted": True,
        "reconnected": True,
        "workspace_sync": True,
        "stable_seconds": int(os.environ["RECONNECT_STABILITY_SECONDS"]),
        "onboarding_complete": (
            True if os.environ["ONBOARDING_COMPLETE"] == "true" else None
        ),
    },
    "artifacts": {
        "pairing_log": "pairing.cmux-debug.log",
        "reconnect_log": "reconnect.cmux-debug.log",
        "pairing_screenshot": "pairing.png",
        "reconnect_screenshot": "reconnect.png",
    },
}
path = Path(os.environ["REPORT_PATH"])
temporary = path.with_suffix(".tmp")
temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
temporary.chmod(0o600)
temporary.replace(path)
PY

echo "DeviceLink E2E passed: $REPORT_PATH"
