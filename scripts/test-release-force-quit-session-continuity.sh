#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <release-app-path>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$1"
if [[ ! -d "$SOURCE_APP/Contents" ]]; then
  echo "release app not found: $SOURCE_APP" >&2
  exit 1
fi
SOURCE_IS_DEEP_SIGNED=0
if /usr/bin/codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1; then
  SOURCE_IS_DEEP_SIGNED=1
fi

TEMP_DIR="$(mktemp -d /tmp/cmux-release-force-quit.XXXXXX)"
TEST_NAME="cmux Mochi RELEASE force-quit"
TEST_APP="$TEMP_DIR/$TEST_NAME.app"
TEST_BUNDLE_ID="com.cmux-mochi.staging.release-force-quit.$(date -u +%Y%m%d%H%M%S).$$"
TEST_TAG="release-force-quit-$$"
TEST_STATE_SLUG="$(printf '%s' "${TEST_BUNDLE_ID#com.cmux-mochi.}" | tr '[:upper:].' '[:lower:]-')"
CMUX_APPLICATION_SUPPORT="$HOME/Library/Application Support/cmux"
CMUX_LOCAL_STATE="$HOME/.local/state/cmux"

cleanup() {
  local test_pid
  local test_pids
  test_pids="$(pgrep -f "$TEST_APP/Contents/MacOS/" || true)"
  while IFS= read -r test_pid; do
    [[ -n "$test_pid" ]] || continue
    kill -9 "$test_pid" 2>/dev/null || true
  done <<<"$test_pids"
  rm -f \
    "$CMUX_APPLICATION_SUPPORT/session-$TEST_BUNDLE_ID.json" \
    "$CMUX_APPLICATION_SUPPORT/session-$TEST_BUNDLE_ID-previous.json" \
    "$CMUX_APPLICATION_SUPPORT/$TEST_STATE_SLUG-last-socket-path" \
    "$CMUX_APPLICATION_SUPPORT/notification-feed-history-$TEST_BUNDLE_ID.json" \
    "$CMUX_LOCAL_STATE/$TEST_STATE_SLUG-last-socket-path" \
    "/tmp/cmux-staging-$TEST_STATE_SLUG-last-socket-path"
  rm -rf \
    "$HOME/Library/Saved Application State/$TEST_BUNDLE_ID.savedState" \
    "$HOME/Library/Caches/$TEST_BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$TEST_BUNDLE_ID"
  rm -rf "$TEMP_DIR"
  defaults delete "$TEST_BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$TEST_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $TEST_NAME" "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $TEST_NAME" "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_BUNDLE_ID" "$TEST_APP/Contents/Info.plist"

# The release candidate keeps its exact executable and resources. Only the
# disposable copy's display/bundle identity changes so the journey cannot read,
# overwrite, launch, or terminate a developer's installed stable or Nightly.
# A CI candidate is already signed inside-out, so preserve every nested
# production signature and replace only the now-invalid main-bundle signature.
# Local unsigned Release builds take the same inside-out signing path with an
# ad-hoc identity so developers can run this gate before publishing.
if [[ "$SOURCE_IS_DEEP_SIGNED" == "1" ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --sign - \
    --timestamp=none \
    --entitlements "$ROOT_DIR/cmux.nightly.entitlements" \
    "$TEST_APP"
else
  CMUX_TIMESTAMP=none "$ROOT_DIR/scripts/sign-cmux-bundle.sh" \
    "$TEST_APP" \
    "$ROOT_DIR/cmux.nightly.entitlements" \
    -
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$TEST_APP"

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TEST_APP/Contents/Info.plist")"
CMUX_FORCE_QUIT_APP_PATH="$TEST_APP" \
CMUX_FORCE_QUIT_BUNDLE_ID="$TEST_BUNDLE_ID" \
CMUX_FORCE_QUIT_EXECUTABLE_NAME="$EXECUTABLE_NAME" \
CMUX_FORCE_QUIT_TEST_CWD="/tmp" \
CMUX_FORCE_QUIT_SOCKET_PATH="$TEMP_DIR/cmux.sock" \
CMUX_FORCE_QUIT_DAEMON_SOCKET_PATH="$TEMP_DIR/cmuxd.sock" \
CMUX_FORCE_QUIT_LOG_PATH="$TEMP_DIR/cmux.log" \
CMUX_FORCE_QUIT_STOP_AFTER_SUCCESS=1 \
CMUX_FORCE_QUIT_DIRECT_EXEC=1 \
  "$ROOT_DIR/scripts/test-force-quit-session-continuity.sh" "$TEST_TAG"
