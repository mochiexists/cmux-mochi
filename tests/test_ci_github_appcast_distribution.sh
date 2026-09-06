#!/usr/bin/env bash
# The Mochi fork publishes Sparkle appcasts as GitHub Release assets. It does
# not own upstream's Cloudflare R2 bucket or credentials.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NIGHTLY_WORKFLOW="$ROOT_DIR/.github/workflows/nightly.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

if grep -Eq '\$\{\{ secrets\.CF_R2_|python3 scripts/ci/upload-r2-object\.py|resolve-aws-cli\.sh' "$NIGHTLY_WORKFLOW" "$RELEASE_WORKFLOW"; then
  echo "FAIL: fork release workflows must not depend on upstream R2 infrastructure"
  exit 1
fi

if ! grep -Fq 'https://github.com/mochiexists/cmux-mochi/releases/download/nightly/appcast.xml' "$NIGHTLY_WORKFLOW"; then
  echo "FAIL: nightly workflow must embed the fork GitHub nightly appcast URL"
  exit 1
fi

if ! grep -Fq 'https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml' "$RELEASE_WORKFLOW"; then
  echo "FAIL: release workflow must embed the fork GitHub stable appcast URL"
  exit 1
fi

if ! awk '
  /^      - name: Publish nightly release assets$/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /uses: softprops\/action-gh-release@/ { saw_action=1 }
  in_step && /^[[:space:]]+appcast\.xml$/ { saw_appcast=1 }
  END { exit !(saw_action && saw_appcast) }
' "$NIGHTLY_WORKFLOW"; then
  echo "FAIL: nightly workflow must publish appcast.xml as a GitHub Release asset"
  exit 1
fi

if ! awk '
  /^      - name: Upload release asset$/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /uses: softprops\/action-gh-release@/ { saw_action=1 }
  in_step && /^[[:space:]]+appcast\.xml$/ { saw_appcast=1 }
  END { exit !(saw_action && saw_appcast) }
' "$RELEASE_WORKFLOW"; then
  echo "FAIL: release workflow must publish appcast.xml as a GitHub Release asset"
  exit 1
fi

echo "PASS: fork appcasts use GitHub Releases without upstream R2 dependencies"
