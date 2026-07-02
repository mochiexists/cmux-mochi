#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
RELEASE_FILE="$ROOT_DIR/.github/workflows/release.yml"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-release-universal.sh"

# nightly.yml is intentionally not covered here. It has its own helper-build
# model and guards via test_ci_nightly_xcode_selection.sh plus
# test_nightly_universal_build.sh. This lane guards the release/CI
# artifact-download model.

job_section() {
  local file="$1" job="$2"
  awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { exit }
    in_job { print }
  ' "$file"
}

require_job_contains() {
  local file="$1" job="$2" needle="$3" message="$4"
  local section
  section="$(job_section "$file" "$job")"
  if [[ "$section" != *"$needle"* ]]; then
    echo "FAIL: $message" >&2
    exit 1
  fi
}

require_job_contains \
  "$RELEASE_FILE" \
  "build-ghostty-cli-helper" \
  'runs-on: macos-15' \
  "release must build the real Ghostty CLI helper on GitHub-hosted macOS 15"

require_job_contains \
  "$RELEASE_FILE" \
  "build-sign-notarize" \
  'runs-on: [self-hosted, cmux-mochi-m4pro]' \
  "release must sign+notarize on the M4 self-hosted GitHub Actions runner after importing the Developer ID intermediate chain"

require_job_contains \
  "$CI_FILE" \
  "release-ghostty-cli-helper" \
  'runs-on: ${{ vars.MACOS_RUNNER_15 || '\''blacksmith-6vcpu-macos-15'\'' }}' \
  "CI must build the real Ghostty CLI helper on macOS 15"

require_job_contains \
  "$CI_FILE" \
  "release-build" \
  'runs-on: ${{ vars.MACOS_RUNNER_26_RELEASE || '\''blacksmith-6vcpu-macos-26'\'' }}' \
  "CI release-build must compile the app on macOS 26 using the release-specific runner variable"

for workflow in "$CI_FILE" "$RELEASE_FILE"; do
  if ! grep -Fq "./scripts/build-release-universal.sh" "$workflow"; then
    echo "FAIL: $(basename "$workflow") must call scripts/build-release-universal.sh for the app build" >&2
    exit 1
  fi

  if ! grep -Fq "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0" "$workflow"; then
    echo "FAIL: $(basename "$workflow") must download the macOS 15-built helper artifact" >&2
    exit 1
  fi

  if ! grep -Fq "./scripts/install-prebuilt-ghostty-cli-helper.sh" "$workflow"; then
    echo "FAIL: $(basename "$workflow") must install the prebuilt Ghostty CLI helper into the app" >&2
    exit 1
  fi

  if ! grep -Fq '[[ "$SDK_VERSION" == 26.* ]]' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must verify the app binary was built with a macOS 26 SDK" >&2
    exit 1
  fi
done

for needle in \
  "CMUX_SKIP_ZIG_BUILD=1" \
  "-jobs 1" \
  "SWIFT_COMPILATION_MODE=singlefile" \
  'ARCHS="arm64 x86_64"' \
  "CODE_SIGNING_ALLOWED=NO"
do
  if ! grep -Fq -- "$needle" "$BUILD_SCRIPT"; then
    echo "FAIL: build-release-universal.sh must preserve release build flag: $needle" >&2
    exit 1
  fi
done

echo "PASS: release and CI app builds use macOS 26 SDK with a macOS 15-built Ghostty CLI helper"
