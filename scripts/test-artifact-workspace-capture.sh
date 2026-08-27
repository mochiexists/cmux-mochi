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
APP="$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}/Build/Products/Debug/${APP_NAME}.app"
CLI="$APP/Contents/Resources/bin/cmux"
SOCKET="/tmp/cmux-debug-${TAG_SLUG}.sock"
DAEMON_SOCKET="$HOME/Library/Application Support/cmux/cmuxd-dev-${TAG_SLUG}.sock"
TEMP_ROOT="$(mktemp -d "/tmp/cmux-artifact-capture-${TAG_SLUG}.XXXXXX")"
ARTIFACT_ROOT="$TEMP_ROOT/artifacts"

if [[ ! -x "$CLI" ]]; then
  echo "tagged app is not built: $APP" >&2
  exit 1
fi

read_default() {
  defaults read "$BUNDLE_ID" "$1" 2>/dev/null || printf '%s' "__unset__"
}

original_pairing="$(read_default mobile.iOSPairingHost.enabled)"
original_artifacts_directory="$(read_default artifacts.directory)"

cleanup() {
  if [[ "$original_pairing" == "__unset__" ]]; then
    defaults delete "$BUNDLE_ID" mobile.iOSPairingHost.enabled >/dev/null 2>&1 || true
  elif [[ "$original_pairing" == "1" ]]; then
    defaults write "$BUNDLE_ID" mobile.iOSPairingHost.enabled -bool true >/dev/null
  else
    defaults write "$BUNDLE_ID" mobile.iOSPairingHost.enabled -bool false >/dev/null
  fi
  if [[ "$original_artifacts_directory" == "__unset__" ]]; then
    defaults delete "$BUNDLE_ID" artifacts.directory >/dev/null 2>&1 || true
  else
    defaults write "$BUNDLE_ID" artifacts.directory "$original_artifacts_directory" >/dev/null
  fi
  if [[ "$TEMP_ROOT" == /tmp/cmux-artifact-capture-* ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

# Pairing has a separate E2E. This desktop rendering journey must never wait on
# an ad-hoc-signature keychain prompt.
defaults write "$BUNDLE_ID" mobile.iOSPairingHost.enabled -bool false
defaults write "$BUNDLE_ID" artifacts.directory "$ARTIFACT_ROOT"

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

if [[ ! -S "$SOCKET" ]] || ! cli ping >/dev/null 2>&1; then
  rm -f "$SOCKET" "$DAEMON_SOCKET"
  env \
    CMUX_SOCKET_MODE=automation \
    CMUX_SOCKET_PATH="$SOCKET" \
    CMUXD_UNIX_PATH="$DAEMON_SOCKET" \
    open -g "$APP"
  deadline=$((SECONDS + 25))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCKET" ]] && cli ping >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
fi

if ! cli ping >/dev/null 2>&1; then
  echo "tagged socket did not become ready: $SOCKET" >&2
  exit 1
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
create_json="$TEMP_ROOT/create.json"
list_json="$TEMP_ROOT/list.json"
capture_json="$TEMP_ROOT/capture.json"

cli rpc artifact.new \
  "{\"kind\":\"html\",\"title\":\"Parity Capture ${run_id}\"}" \
  >"$create_json"

surface_id="$(python3 - "$create_json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(payload, dict) and isinstance(payload.get("result"), dict):
    payload = payload["result"]
surface_id = payload.get("surface_id") if isinstance(payload, dict) else None
if not surface_id:
    raise SystemExit("artifact.new returned no surface_id")
print(surface_id)
PY
)"

cli rpc artifact.list '{}' >"$list_json"
python3 - "$list_json" "$run_id" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(payload, dict) and isinstance(payload.get("result"), dict):
    payload = payload["result"]
records = payload.get("records", []) if isinstance(payload, dict) else []
if not any(sys.argv[2] in str(record.get("title", "")) for record in records):
    raise SystemExit("artifact.list omitted the newly created artifact")
PY

# Let WebKit mount and render before asking the shipped capture path to take its
# visible snapshot.
sleep 1
cli rpc workspace.screenshot '{"include_base64":false}' >"$capture_json"
python3 - "$capture_json" "$surface_id" <<'PY'
import json
import os
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(payload, dict) and isinstance(payload.get("result"), dict):
    payload = payload["result"]
if not isinstance(payload, dict):
    raise SystemExit("workspace.screenshot returned an invalid payload")
image_path = payload.get("path")
if not image_path or not os.path.isfile(image_path) or os.path.getsize(image_path) == 0:
    raise SystemExit("workspace.screenshot did not write a non-empty image")
panes = payload.get("panes", [])
matches = [pane for pane in panes if pane.get("surface_id") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit("workspace.screenshot omitted the artifact pane")
pane = matches[0]
if pane.get("surface_type") != "artifact" or pane.get("captured") is not True:
    raise SystemExit(f"artifact pane was not composited: {pane}")
print(image_path)
PY

echo "artifact create/list/workspace-capture journey passed"
echo "tag: $TAG"
echo "surface: $surface_id"
