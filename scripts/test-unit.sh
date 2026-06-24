#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="cmux.xcodeproj"
SCHEME="cmux-unit"
CONFIGURATION="${CMUX_TEST_CONFIGURATION:-Debug}"
DESTINATION="${CMUX_TEST_DESTINATION:-platform=macOS}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

# Quarantined: hangs on teardown in our macOS test host (real window-server /
# display-link teardown; byte-identical to upstream, not a fork regression).
# Keep in sync with QUARANTINED_SELECTORS in scripts/ci/cmux_unit_test_shard.py.
SKIP_QUARANTINED=()
for arg in "$@"; do
  case "$arg" in
    test|test-without-building|build-for-testing)
      SKIP_QUARANTINED+=(-skip-testing:cmuxTests/AppDelegateShortcutRoutingTests/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace)
      break
      ;;
  esac
done

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  ${SKIP_QUARANTINED[@]+"${SKIP_QUARANTINED[@]}"} \
  "$@"
