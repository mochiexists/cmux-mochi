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

require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_BUNDLE_IDENTIFIER = "com.cmux-mochi";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_BUNDLE_IDENTIFIER = "com.cmux-mochi.debug";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_BUNDLE_IDENTIFIER = "com.cmux-mochi.tests";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_BUNDLE_IDENTIFIER = "com.cmux-mochi.uitests";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_BUNDLE_IDENTIFIER = "com.cmux-mochi.docktileplugin";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_NAME = "cmux Mochi";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'PRODUCT_NAME = "cmux Mochi DEV";'
require_file_contains "cmux.xcodeproj/project.pbxproj" 'SPARKLE_PUBLIC_KEY = "zuKEVdkteBH5X33sMtjNnINr5JfskPx6Yj4LxZlySfY=";'
require_file_contains "cmux.xcodeproj/project.pbxproj" "CURRENT_PROJECT_VERSION = "
require_file_contains "cmux.xcodeproj/project.pbxproj" "MARKETING_VERSION = "

# Runtime identity constants: tagged debug/staging/nightly socket isolation and
# push routing break silently if these revert to upstream com.cmuxterm values
# (caught live 2026-07-17: tagged DEV build bound the shared /tmp/cmux-debug.sock).
require_file_contains "Packages/macOS/CmuxSettings/Sources/CmuxSettings/SocketControl/SocketPathMarkerFiles.swift" 'nightlyBundleIdentifier = "com.cmux-mochi.nightly"'
require_file_contains "Packages/macOS/CmuxSettings/Sources/CmuxSettings/SocketControl/SocketPathMarkerFiles.swift" 'stagingBundleIdentifier = "com.cmux-mochi.staging"'
require_file_contains "Packages/macOS/CmuxSettings/Sources/CmuxSettings/SocketControl/SocketPathMarkerFiles.swift" 'defaultBaseDebugBundleIdentifier = "com.cmux-mochi.debug"'
require_file_contains "Packages/macOS/CmuxSettings/Sources/CmuxSettings/SocketControl/SocketControlSettings.swift" 'baseDebugBundleIdentifier = "com.cmux-mochi.debug"'
require_file_contains "web/services/apns/routePolicy.ts" 'PROD_BUNDLE_IDS = new Set(["com.cmux-mochi", "dev.cmux.app.beta"])'

# Upstream's scheduled TUI nightly must stay cron-disabled on the fork
# (workflow_dispatch only); a rebase can silently restore the schedule.
if grep -Eq '^[[:space:]]+schedule:' "$ROOT_DIR/.github/workflows/cmux-tui-nightly.yml"; then
  fail "cmux-tui-nightly.yml has an active schedule trigger; keep the cron commented out on the fork"
fi

require_file_contains "Resources/Info.plist" "https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml"
require_file_contains "Resources/Info.plist" '$(SPARKLE_PUBLIC_KEY)'

require_file_contains ".github/workflows/release.yml" "mochiexists/cmux-mochi"
require_file_contains ".github/workflows/release.yml" "codes-o3"
require_file_contains ".github/workflows/release.yml" "https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml"
require_file_contains ".github/workflows/release.yml" "build-ghostty-cli-helper"
require_file_contains ".github/workflows/release.yml" "scripts/import-apple-developer-id-intermediates.sh build.keychain"
require_file_contains ".github/workflows/release.yml" "runs-on: macos-15"
require_file_contains ".github/workflows/release.yml" "runs-on: [self-hosted, cmux-mochi-m4pro]"
require_file_absent ".github/workflows/release.yml" "files.cmux.com"
require_file_absent ".github/workflows/release.yml" "blacksmith-"
require_file_contains ".github/workflows/build-ghosttykit.yml" "mochiexists/ghostty"
require_file_contains "scripts/download-prebuilt-ghosttykit.sh" "mochiexists/ghostty"

require_file_contains ".github/workflows/nightly.yml" "mochiexists/cmux-mochi"
require_file_contains ".github/workflows/nightly.yml" "codes-o3"
require_file_contains ".github/workflows/nightly.yml" "scripts/import-apple-developer-id-intermediates.sh build.keychain"
require_file_contains ".github/workflows/nightly.yml" '["self-hosted","cmux-mochi-m4pro"]'
require_file_contains ".github/workflows/nightly.yml" "blacksmith-6vcpu-macos-15"
require_file_contains ".github/workflows/nightly.yml" "https://github.com/mochiexists/cmux-mochi/releases/download/nightly/appcast.xml"
require_file_absent ".github/workflows/nightly.yml" "files.cmux.com"

require_file_contains ".github/workflows/ios-testflight.yml" "599WAZ6282.dev.cmux.app.beta"
require_file_contains "ios/README.md" "team \`599WAZ6282\`"
require_file_absent ".github/workflows/ios-testflight.yml" "7WLXT3NR37"
require_file_absent "ios/README.md" "7WLXT3NR37"

require_file_contains "web/data/cmux.schema.json" "raw.githubusercontent.com/mochiexists/cmux-mochi/main/web/data/cmux.schema.json"
require_file_contains "web/data/cmux-settings.schema.json" "raw.githubusercontent.com/mochiexists/cmux-mochi/main/web/data/cmux.schema.json"
require_file_contains "web/app/[locale]/nightly/page.tsx" "https://github.com/mochiexists/cmux-mochi/releases/download/nightly/cmux-nightly-macos.dmg"
require_file_contains "web/app/[locale]/nightly/page.tsx" "https://github.com/mochiexists/cmux-mochi/issues"
require_file_contains "web/app/[locale]/(landing)/nightly/page.tsx" "https://github.com/mochiexists/cmux-mochi/releases/download/nightly/cmux-nightly-macos.dmg"
require_file_contains "web/app/[locale]/(landing)/nightly/page.tsx" "https://github.com/mochiexists/cmux-mochi/issues"
require_file_absent "web/data/cmux.schema.json" "manaflow-ai/cmux"
require_file_absent "web/data/cmux-settings.schema.json" "manaflow-ai/cmux"
require_file_absent "web/app/[locale]/nightly/page.tsx" "manaflow-ai/cmux"
require_file_absent "web/app/[locale]/(landing)/nightly/page.tsx" "manaflow-ai/cmux"

require_file_contains ".github/workflows/update-homebrew.yml" "auto-trigger disabled"
require_file_contains ".github/workflows/update-homebrew.yml" "mochiexists/cmux-mochi"
require_file_contains ".github/workflows/update-homebrew.yml" "github.repository == 'manaflow-ai/cmux'"
require_file_contains ".github/workflows/presence.yml" "github.repository == 'manaflow-ai/cmux'"
require_file_contains ".github/workflows/cloud-vm-migrate.yml" "github.repository == 'manaflow-ai/cmux'"
require_file_contains ".github/workflows/cloud-vm-smoke.yml" "github.repository == 'manaflow-ai/cmux'"
require_file_contains ".github/workflows/test-depot.yml" "github.repository == 'manaflow-ai/cmux'"
require_file_contains "FORK.md" "com.cmux-mochi"

# cmux-mochi Sentry project (codes-o3/cmux-mochi, project 4511385382486096).
require_file_contains "CLI/CLISocketSentryTelemetry.swift" "https://f1724042a52588425266851138bb2ee8@o4510776019910656.ingest.de.sentry.io/4511385382486096"
require_file_contains "Sources/AppDelegate.swift" "https://f1724042a52588425266851138bb2ee8@o4510776019910656.ingest.de.sentry.io/4511385382486096"
# Forbid the upstream US DSN and the wrong-project cmux-atlas DSN (4511100296101968).
require_file_absent "CLI/CLISocketSentryTelemetry.swift" "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
require_file_absent "Sources/AppDelegate.swift" "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
require_file_absent "CLI/CLISocketSentryTelemetry.swift" "4511100296101968"
require_file_absent "Sources/AppDelegate.swift" "4511100296101968"
# Symbol upload must target the same project (else crashes don't symbolicate).
require_file_contains ".github/workflows/release.yml" "SENTRY_PROJECT: cmux-mochi"
require_file_contains ".github/workflows/nightly.yml" "SENTRY_PROJECT: cmux-mochi"
require_file_absent ".github/workflows/release.yml" "SENTRY_PROJECT: cmux-atlas"
require_file_absent ".github/workflows/nightly.yml" "SENTRY_PROJECT: cmux-atlas"

require_command_output "https://github.com/mochiexists/bonsplit.git" \
  git -C "$ROOT_DIR" config --file .gitmodules --get submodule.vendor/bonsplit.url

bonsplit_pointer="$(git -C "$ROOT_DIR" ls-tree HEAD vendor/bonsplit | awk '{print $3}')"
if [[ "$bonsplit_pointer" != "033ba4cb8e0c3373d82edc0a82e2d5b3cc7ce959" ]]; then
  fail "vendor/bonsplit is not pinned to 033ba4cb8e0c3373d82edc0a82e2d5b3cc7ce959: $bonsplit_pointer"
fi

require_file_contains "scripts/reload.sh" 'APP_NAME="cmux Mochi DEV"'
require_file_contains "scripts/reload.sh" 'BUNDLE_ID="com.cmux-mochi.debug"'
require_file_contains "scripts/cmux-debug-cli.sh" 'cmux Mochi DEV ${tag_slug}.app/Contents/Resources/bin/cmux'
require_file_absent "scripts/cmux-debug-cli.sh" 'cmux DEV ${tag_slug}.app/Contents/Resources/bin/cmux'
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
