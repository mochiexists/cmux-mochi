#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/curl" <<'SH'
#!/usr/bin/env bash
exit 22
SH

cat > "$TMP_DIR/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${GH_RESPONSE:-[]}"
SH

chmod +x "$TMP_DIR/curl" "$TMP_DIR/gh"

run_guard() {
  PATH="$TMP_DIR:$PATH" "$ROOT_DIR/scripts/release-pretag-guard.sh" "$@"
}

export GH_RESPONSE='[{"status":"completed","conclusion":"success"}]'
if ! run_guard >"$TMP_DIR/success.out" 2>"$TMP_DIR/success.err"; then
  cat "$TMP_DIR/success.out"
  cat "$TMP_DIR/success.err" >&2
  echo "FAIL: release pretag guard should pass when HEAD CI succeeded" >&2
  exit 1
fi

export GH_RESPONSE='[]'
if run_guard >"$TMP_DIR/missing.out" 2>"$TMP_DIR/missing.err"; then
  echo "FAIL: release pretag guard should fail when no HEAD CI run exists" >&2
  exit 1
fi
if ! grep -Fq "no completed successful ci.yml run exists" "$TMP_DIR/missing.err"; then
  cat "$TMP_DIR/missing.err" >&2
  echo "FAIL: missing-run error should explain the exact-HEAD CI requirement" >&2
  exit 1
fi

export GH_RESPONSE='[{"status":"completed","conclusion":"failure"}]'
if run_guard >"$TMP_DIR/failure.out" 2>"$TMP_DIR/failure.err"; then
  echo "FAIL: release pretag guard should fail when HEAD CI failed" >&2
  exit 1
fi

export GH_RESPONSE='[]'
if ! run_guard --skip-ci-check >"$TMP_DIR/skip.out" 2>"$TMP_DIR/skip.err"; then
  cat "$TMP_DIR/skip.out"
  cat "$TMP_DIR/skip.err" >&2
  echo "FAIL: --skip-ci-check should allow offline release preparation" >&2
  exit 1
fi
if ! grep -Fq "skipping exact-HEAD CI success check" "$TMP_DIR/skip.err"; then
  cat "$TMP_DIR/skip.err" >&2
  echo "FAIL: --skip-ci-check should print a warning" >&2
  exit 1
fi

echo "PASS: release pretag guard enforces exact-HEAD CI success"
