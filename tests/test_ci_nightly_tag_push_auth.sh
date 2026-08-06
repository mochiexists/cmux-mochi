#!/usr/bin/env bash
# Guards the nightly tag update against regressions to the auth approach.
#
# History:
# - Originally relied on actions/checkout-persisted credentials, which
#   intermittently failed with `fatal: could not read Username for
#   'https://github.com': Device not configured` on the self-hosted runner.
# - Then overlaid a second Authorization header via `-c
#   http.https://github.com/.extraheader=AUTHORIZATION: basic …`, which made
#   GitHub reject the push with `remote: Duplicate header: "Authorization"`
#   because the persisted extraheader was still in effect.
# - Now pushes to an explicit tokenized URL so the push neither depends on
#   persisted creds nor overlays a second Authorization header.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

# Fork (cmux Mochi): the fork has no nightly tag to move.
#
# `409930e7c5 fork: re-apply Mochi CI/release workflow overlay` removed the
# "Move nightly tag to built commit" step: this fork cuts nightlies ad-hoc from a
# working branch and publishes only on main, so nothing ever repoints a `nightly`
# tag. Asserting the step exists made the guard fail on a workflow that is
# correct by design — and because `linux-preflight` gates on this job, that one
# red guard cascaded into skipping the Swift test jobs entirely.
#
# Absence is therefore a pass. The auth assertions below still apply in full if
# the step ever returns, so the regressions in the history above stay guarded.
if ! grep -q '^      - name: Move nightly tag to built commit' "$WORKFLOW_FILE"; then
  echo "PASS: no nightly tag push step in this workflow (fork publishes on main only)"
  exit 0
fi

if ! awk '
  /^      - name: Move nightly tag to built commit/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /GITHUB_TOKEN: \$\{\{ github\.token \}\}/ { saw_token_env=1 }
  in_step && /x-access-token:\$\{GITHUB_TOKEN\}@github\.com\/\$\{GITHUB_REPOSITORY\}\.git/ { saw_token_url=1 }
  in_step && /refs\/tags\/nightly --force/ { saw_push=1 }
  in_step && /\.extraheader=AUTHORIZATION/ { saw_extraheader=1 }
  END {
    if (saw_extraheader) exit 1
    exit !(saw_token_env && saw_token_url && saw_push)
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly tag push must use a tokenized https URL with github.token (no extraheader overlay)"
  exit 1
fi

echo "PASS: nightly tag push uses tokenized https URL with github.token"
