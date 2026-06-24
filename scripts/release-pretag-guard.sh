#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running release pre-tag checks..."
echo "Running fork overlay audit..."
"$ROOT_DIR/scripts/fork-overlay-audit.sh"
echo "Running Sparkle build monotonic check..."
"$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
echo "Release pre-tag checks passed."
