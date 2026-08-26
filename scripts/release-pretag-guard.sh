#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running release pre-tag checks..."
"$ROOT_DIR/scripts/fork-overlay-audit.sh"
"$ROOT_DIR/scripts/test-fork-parity.sh"
"$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
python3 "$ROOT_DIR/tests/test_fork_parity_validation.py"
python3 "$ROOT_DIR/scripts/check-fork-parity-validation.py" \
  "$ROOT_DIR/plans/clean-trunk-v0.64.22/VALIDATION-MATRIX.md"
echo "Release pre-tag checks passed."
