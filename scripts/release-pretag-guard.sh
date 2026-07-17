#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SKIP_CI_CHECK=0
RUN_BUILD=0

usage() {
  cat <<'EOF'
usage: release-pretag-guard.sh [--skip-ci-check] [--build]

Runs release pre-tag checks. By default this requires a successful completed
ci.yml run on the exact local HEAD.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ci-check)
      SKIP_CI_CHECK=1
      shift
      ;;
    --build)
      RUN_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

echo "Running release pre-tag checks..."
"$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
"$ROOT_DIR/scripts/fork-overlay-audit.sh"

if [[ "$SKIP_CI_CHECK" == "1" ]]; then
  echo "WARNING: skipping exact-HEAD CI success check by request." >&2
else
  HEAD_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  echo "Checking for successful ci.yml run on HEAD $HEAD_SHA..."
  RUNS_JSON="$(gh run list \
    --repo mochiexists/cmux-mochi \
    --commit "$HEAD_SHA" \
    --workflow ci.yml \
    --json conclusion,status)"
  if ! python3 - "$RUNS_JSON" <<'PY'
import json
import sys

runs = json.loads(sys.argv[1])
for run in runs:
    if run.get("status") == "completed" and run.get("conclusion") == "success":
        sys.exit(0)
sys.exit(1)
PY
  then
    cat >&2 <<EOF
FAIL: no completed successful ci.yml run exists for HEAD $HEAD_SHA.

Run CI for this exact commit before tagging, or rerun with --skip-ci-check only
for a deliberate offline/local release.
EOF
    exit 1
  fi
fi

if [[ "$RUN_BUILD" == "1" ]]; then
  "$ROOT_DIR/scripts/build-release-universal.sh"
fi

echo "Release pre-tag checks passed."
