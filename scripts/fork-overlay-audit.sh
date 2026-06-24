#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "fork overlay audit failed: $*" >&2
  exit 1
}

require_file_contains() {
  local file="$1"
  local needle="$2"

  if ! grep -Fq "$needle" "$ROOT_DIR/$file"; then
    fail "$file does not contain: $needle"
  fi
}

require_file_absent() {
  local file="$1"
  local needle="$2"

  if grep -Fq "$needle" "$ROOT_DIR/$file"; then
    fail "$file still contains upstream value: $needle"
  fi
}

require_command_output() {
  local expected="$1"
  shift

  local actual
  actual="$("$@")"
  if [[ "$actual" != "$expected" ]]; then
    fail "unexpected output from $*: $actual"
  fi
}

echo "Auditing cmux Mochi fork overlay..."

require_file_contains "cmux.xcodeproj/project.pbxproj" "PRODUCT_BUNDLE_IDENTIFIER = com.cmux-mochi;"
require_file_contains "cmux.xcodeproj/project.pbxproj" "PRODUCT_BUNDLE_IDENTIFIER = com.cmux-mochi.debug;"
require_file_contains "cmux.xcodeproj/project.pbxproj" "PRODUCT_BUNDLE_IDENTIFIER = com.cmux-mochi.tests;"
require_file_contains "cmux.xcodeproj/project.pbxproj" "PRODUCT_BUNDLE_IDENTIFIER = com.cmux-mochi.uitests;"
require_file_contains "cmux.xcodeproj/project.pbxproj" "PRODUCT_BUNDLE_IDENTIFIER = com.cmux-mochi.docktileplugin;"
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_NAME = "cmux Mochi";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_NAME = "cmux Mochi DEV";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'SPARKLE_PUBLIC_KEY = "zuKEVdkteBH5X33sMtjNnINr5JfskPx6Yj4LxZlySfY=";'
require_file_contains "cmux.xcodeproj/project.pbxproj" "CURRENT_PROJECT_VERSION = 102;"
require_file_contains "cmux.xcodeproj/project.pbxproj" "MARKETING_VERSION = 0.64.157;"

require_file_contains "Resources/Info.plist" "https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml"
require_file_contains "Resources/Info.plist" '$(SPARKLE_PUBLIC_KEY)'

require_file_contains ".github/workflows/release.yml" "mochiexists/cmux-mochi"
require_file_contains ".github/workflows/release.yml" "codes-o3"
require_file_contains ".github/workflows/release.yml" "cmux-atlas"
require_file_contains ".github/workflows/release.yml" "Skipping R2 stable appcast mirror: CF_R2 credentials not configured."
require_file_contains ".github/workflows/release.yml" "build-ghostty-cli-helper"
require_file_contains ".github/workflows/release.yml" "scripts/import-apple-developer-id-intermediates.sh build.keychain"
require_file_contains ".github/workflows/release.yml" "blacksmith-6vcpu-macos-15"
require_file_contains ".github/workflows/release.yml" "blacksmith-6vcpu-macos-26"

require_file_contains ".github/workflows/nightly.yml" "mochiexists/cmux-mochi"
require_file_contains ".github/workflows/nightly.yml" "codes-o3"
require_file_contains ".github/workflows/nightly.yml" "cmux-atlas"
require_file_contains ".github/workflows/nightly.yml" "scripts/import-apple-developer-id-intermediates.sh build.keychain"
require_file_contains ".github/workflows/nightly.yml" "blacksmith-6vcpu-macos-15"
require_file_contains ".github/workflows/nightly.yml" "Skipping R2 nightly appcast upload: CF_R2 credentials not configured."

require_file_contains ".github/workflows/ios-testflight.yml" "599WAZ6282.dev.cmux.app.beta"
require_file_contains "ios/README.md" "team \`599WAZ6282\`"
require_file_absent ".github/workflows/ios-testflight.yml" "7WLXT3NR37"
require_file_absent "ios/README.md" "7WLXT3NR37"

require_file_contains "web/data/cmux.schema.json" "raw.githubusercontent.com/mochiexists/cmux-mochi/main/web/data/cmux.schema.json"
require_file_contains "web/data/cmux-settings.schema.json" "raw.githubusercontent.com/mochiexists/cmux-mochi/main/web/data/cmux.schema.json"
require_file_contains "web/app/[locale]/nightly/page.tsx" "https://github.com/mochiexists/cmux-mochi/releases/download/nightly/cmux-nightly-macos.dmg"
require_file_contains "web/app/[locale]/nightly/page.tsx" "https://github.com/mochiexists/cmux-mochi/issues"
require_file_absent "web/data/cmux.schema.json" "manaflow-ai/cmux"
require_file_absent "web/data/cmux-settings.schema.json" "manaflow-ai/cmux"
require_file_absent "web/app/[locale]/nightly/page.tsx" "manaflow-ai/cmux"

require_file_contains ".github/workflows/update-homebrew.yml" "auto-trigger disabled"
require_file_contains ".github/workflows/update-homebrew.yml" "mochiexists/cmux-mochi"

require_file_contains "CLI/CLISocketSentryTelemetry.swift" "https://cf9f50c96d0e1872f0f774d70da71b1c@o4510776019910656.ingest.de.sentry.io/4511100296101968"
require_file_contains "Sources/AppDelegate.swift" "https://cf9f50c96d0e1872f0f774d70da71b1c@o4510776019910656.ingest.de.sentry.io/4511100296101968"
require_file_absent "CLI/CLISocketSentryTelemetry.swift" "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
require_file_absent "Sources/AppDelegate.swift" "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"

require_command_output "https://github.com/mochiexists/bonsplit.git" \
  git -C "$ROOT_DIR" config --file .gitmodules --get submodule.vendor/bonsplit.url

bonsplit_status="$(git -C "$ROOT_DIR" submodule status vendor/bonsplit)"
if [[ "$bonsplit_status" != " 122b99cbf9d3bef36dc94b02032531cfd93a5849 vendor/bonsplit"* ]]; then
  fail "vendor/bonsplit is not pinned to 122b99cbf9d3bef36dc94b02032531cfd93a5849: $bonsplit_status"
fi

require_file_contains "scripts/reload.sh" 'APP_NAME="cmux Mochi DEV"'
require_file_contains "scripts/reload.sh" 'BUNDLE_ID="com.cmux-mochi.debug"'
require_file_contains "scripts/sparkle_generate_appcast.sh" 'https://github.com/mochiexists/cmux-mochi/releases/download/$TAG/'
require_file_contains "scripts/build-sign-upload.sh" "mochiexists/cmux-mochi"
require_file_contains "scripts/build-sign-upload.sh" "UPDATE_HOMEBREW:-0"

if rg -n "rollout.*exist|exists.*rollout|FileManager.*rollout|rolloutPath" "$ROOT_DIR/Sources/RestorableAgentSession.swift" >/dev/null; then
  fail "Sources/RestorableAgentSession.swift appears to contain a codex rollout-existence restorability check"
fi

require_file_contains "cmuxTests/RestorableAgentSessionIndexTests.swift" "cxy"
require_file_contains "cmuxTests/SessionPersistenceTests.swift" "ccy"

plutil -lint "$ROOT_DIR/cmux.xcodeproj/project.pbxproj" >/dev/null

echo "Fork overlay audit passed."
