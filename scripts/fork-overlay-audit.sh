#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_DSN="https://f1724042a52588425266851138bb2ee8@o4510776019910656.ingest.de.sentry.io/4511385382486096"
UPSTREAM_DSN="https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"

fail() {
  echo "fork overlay audit failed: $*" >&2
  exit 1
}

require_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$ROOT_DIR/$file" || fail "$file does not contain: $text"
}

require_absent() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$ROOT_DIR/$file"; then
    fail "$file contains forbidden fork-regression value: $text"
  fi
}

echo "Auditing cmux Mochi fork overlay..."

"$ROOT_DIR/scripts/inject-fork-identity.sh" --check
python3 "$ROOT_DIR/tests/test_fork_identity.py"

require_contains "fork-identity.json" '"owner": "mochiexists"'
require_contains "fork-identity.json" '"name": "cmux-mochi"'
require_contains "fork-identity.json" '"team_id": "599WAZ6282"'
require_contains "fork-identity.json" '"bundle_id": "com.cmux-mochi"'
require_contains "Resources/Info.plist" "https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml"

require_contains ".github/workflows/nightly.yml" "mochiexists/cmux-mochi"
require_contains ".github/workflows/nightly.yml" "SENTRY_PROJECT: cmux-mochi"
require_contains ".github/workflows/release.yml" "mochiexists/cmux-mochi"
require_contains ".github/workflows/release.yml" "SENTRY_PROJECT: cmux-mochi"
require_absent ".github/workflows/nightly.yml" "https://files.cmux.com"
require_absent ".github/workflows/release.yml" "https://files.cmux.com"

require_contains "Sources/AppDelegate.swift" "$FORK_DSN"
require_contains "CLI/CLISocketSentryTelemetry.swift" "$FORK_DSN"
require_absent "Sources/AppDelegate.swift" "$UPSTREAM_DSN"
require_absent "CLI/CLISocketSentryTelemetry.swift" "$UPSTREAM_DSN"

require_contains ".github/workflows/ios-testflight.yml" "com.cmux-mochi.ios"
require_contains "ios/Config/Release.xcconfig" "com.cmux-mochi.ios"
require_absent ".github/workflows/ios-testflight.yml" "7WLXT3NR37"

"$ROOT_DIR/scripts/lint-pbxproj-test-wiring.sh" --repo-root "$ROOT_DIR"
python3 "$ROOT_DIR/scripts/check-fork-parity-ledger.py" \
  "$ROOT_DIR/plans/clean-trunk-v0.64.22/FEATURE-LEDGER.md"
plutil -lint "$ROOT_DIR/cmux.xcodeproj/project.pbxproj" >/dev/null

echo "Fork overlay audit passed."
