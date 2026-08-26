#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${CMUX_PARITY_DERIVED_DATA_PATH:-/tmp/cmux-fork-parity}"
LOG_DIR="${CMUX_PARITY_LOG_DIR:-/tmp/cmux-fork-parity-logs}"
SPM_ROOT="${CMUX_PARITY_SPM_ROOT:-/tmp/cmux-fork-parity-spm}"

mkdir -p "$LOG_DIR" "$SPM_ROOT"
cd "$ROOT_DIR"

run_package_suite() {
  local package_name="$1"
  local selector="$2"
  local log_path="$LOG_DIR/package-${package_name}-${selector}.log"

  echo "==> $package_name/$selector"
  swift test \
    --package-path "Packages/macOS/$package_name" \
    --scratch-path "$SPM_ROOT/$package_name" \
    --filter "$selector" 2>&1 | tee "$log_path"
  "$ROOT_DIR/scripts/ci/require_selected_test_execution.sh" "$log_path" "$selector"
}

run_app_host_suites() {
  local tag="parity-app-host"
  local log_path=""
  local -a only_testing_args=()

  for suite in "${APP_HOST_SUITES[@]}"; do
    only_testing_args+=("-only-testing:cmuxTests/$suite")
  done

  echo "==> cmuxTests focused parity suites"
  CMUX_TAG="$tag" \
  RUNNER_TEMP="$LOG_DIR" \
  "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" \
    -project cmux.xcodeproj \
    -scheme cmux-unit \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS" \
    CMUX_SKIP_ZIG_BUILD=1 \
    "${only_testing_args[@]}" \
    test

  for candidate in "$LOG_DIR/cmux-app-host-xcodebuild-${tag}-attempt-"*.log; do
    if [[ -f "$candidate" ]]; then
      log_path="$candidate"
    fi
  done
  if [[ -z "$log_path" ]]; then
    echo "fork parity app-host test log missing" >&2
    exit 1
  fi
  "$ROOT_DIR/scripts/ci/require_selected_test_execution.sh" "$log_path" "combined app-host parity selection"
  for index in "${!APP_HOST_SUITES[@]}"; do
    if ! grep -Fq "${APP_HOST_EVIDENCE[$index]}" "$log_path"; then
      echo "fork parity selector did not produce passing evidence: cmuxTests/${APP_HOST_SUITES[$index]}" >&2
      exit 1
    fi
  done
}

run_package_suite "CmuxWorkspaces" "WorkspaceRightSidePlacementPlannerTests"
run_package_suite "CmuxFoundation" "MountedWorkspacePresentationTests"
run_package_suite "CmuxUpdaterUI" "UpdatePillPopoverResizeTests"
run_package_suite "CmuxSettingsUI" "ProUpgradePresentationPolicyTests"

APP_HOST_SUITES=(
  CMUXCLISendSubmitWaitTests
  CMUXCLIWelcomeRegressionTests
  CMUXCLISentryTelemetryRegressionTests
  MacSentryStartupPolicyTests
  FilePreviewPanelTextSavingTests/testCmdClickFilePreviewRoutingReusesRightSidePane
  FilePreviewPanelTextSavingTests/testCmdClickMarkdownRoutingReusesRightSidePane
  MarkdownPanelTests/testControlMarkdownOpenReusesExistingRightSidePane
  MobileHostAuthorizationTests
  PaneZoomSessionPersistenceTests
  PrivacyFrostParityTests
  SessionPersistenceTests/testMetadataAutosavePreservesCapturedScrollbackForForceQuitRecovery
  TaskManagerResourcesTests
  TaskManagerSurfaceParityTests
)
APP_HOST_EVIDENCE=(
  'Suite "cmux send submit and wait" passed'
  'Suite "Mochi CLI welcome" passed'
  'Suite CMUXCLISentryTelemetryRegressionTests passed'
  'Suite MacSentryStartupPolicyTests passed'
  "Test Case '-[cmuxTests.FilePreviewPanelTextSavingTests testCmdClickFilePreviewRoutingReusesRightSidePane]' passed"
  "Test Case '-[cmuxTests.FilePreviewPanelTextSavingTests testCmdClickMarkdownRoutingReusesRightSidePane]' passed"
  "Test Case '-[cmuxTests.MarkdownPanelTests testControlMarkdownOpenReusesExistingRightSidePane]' passed"
  'Suite MobileHostAuthorizationTests passed'
  'Suite "Pane zoom session persistence" passed'
  'Suite "Privacy Frost parity" passed'
  "Test Case '-[cmuxTests.SessionPersistenceTests testMetadataAutosavePreservesCapturedScrollbackForForceQuitRecovery]' passed"
  "Test Suite 'TaskManagerResourcesTests' passed"
  'Suite TaskManagerSurfaceParityTests passed'
)
run_app_host_suites

echo "Fork parity focused suites passed with non-zero execution."
