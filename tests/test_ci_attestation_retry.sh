#!/usr/bin/env bash
# Guard release/nightly provenance attestation against transient Sigstore/Rekor
# network failures. Nightly requires the retry; the fork's production release
# records a warning after two failed attempts and continues by policy.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTION='actions/attest-build-provenance@a2bbfa25375fe432b6a289bc6b6cd05ecd0c4c32'

check_attestation_retry() {
  local file="$1"
  local first_step="$2"
  local first_id="$3"
  local retry_step="$4"
  local subject_marker="$5"
  local retry_policy="$6"

  if ! awk -v first_step="$first_step" -v first_id="$first_id" -v action="$ACTION" -v subject="$subject_marker" '
    $0 ~ "^[[:space:]]*- name: " first_step "$" { in_step=1; next }
    in_step && /^      - name:/ { in_step=0 }
    in_step && $0 ~ "id: " first_id "$" { saw_id=1 }
    in_step && /continue-on-error:[[:space:]]*true/ { saw_continue=1 }
    in_step && index($0, "uses: " action) { saw_action=1 }
    in_step && index($0, subject) { saw_subject=1 }
    END { exit !(saw_id && saw_continue && saw_action && saw_subject) }
  ' "$file"; then
    echo "FAIL: $(basename "$file") first attestation step must have id=$first_id, continue-on-error, pinned action, and expected subject"
    exit 1
  fi

  if ! awk -v retry_step="$retry_step" -v first_id="$first_id" -v action="$ACTION" -v subject="$subject_marker" -v retry_policy="$retry_policy" '
    $0 ~ "^[[:space:]]*- name: " retry_step "$" { in_step=1; next }
    in_step && /^      - name:/ { in_step=0 }
    in_step && index($0, "steps." first_id ".outcome == '\''failure'\''") { saw_outcome=1 }
    in_step && index($0, "uses: " action) { saw_action=1 }
    in_step && index($0, subject) { saw_subject=1 }
    in_step && /continue-on-error:[[:space:]]*true/ { saw_retry_continue=1 }
    END {
      policy_matches = retry_policy == "warn" ? saw_retry_continue : !saw_retry_continue
      exit !(saw_outcome && saw_action && saw_subject && policy_matches)
    }
  ' "$file"; then
    echo "FAIL: $(basename "$file") retry attestation step does not match the $retry_policy policy"
    exit 1
  fi

  echo "PASS: $(basename "$file") remote daemon asset attestation uses the $retry_policy retry policy"
}

check_release_attestation_warning() {
  local file="$1"

  if ! awk '
    /^[[:space:]]*- name: Warn if remote daemon release asset attestation failed$/ { in_step=1; next }
    in_step && /^      - name:/ { in_step=0 }
    in_step && index($0, "steps.retry-remote-daemon-release-asset-attestation.outcome == '\''failure'\''") { saw_outcome=1 }
    in_step && /::warning::Remote daemon release asset provenance attestation failed after retry/ { saw_warning=1 }
    END { exit !(saw_outcome && saw_warning) }
  ' "$file"; then
    echo "FAIL: release.yml must warn when both release attestation attempts fail"
    exit 1
  fi

  echo "PASS: release.yml warns when both release attestation attempts fail"
}

check_attestation_retry \
  "$ROOT_DIR/.github/workflows/nightly.yml" \
  "Attest remote daemon nightly assets" \
  "attest-remote-daemon-nightly-assets" \
  "Retry remote daemon nightly asset attestation" \
  'remote-daemon-assets/cmuxd-remote-manifest-${{ env.NIGHTLY_BUILD }}.json' \
  "required"

check_attestation_retry \
  "$ROOT_DIR/.github/workflows/release.yml" \
  "Attest remote daemon release assets" \
  "attest-remote-daemon-release-assets" \
  "Retry remote daemon release asset attestation" \
  "remote-daemon-assets/cmuxd-remote-manifest.json" \
  "warn"

check_release_attestation_warning "$ROOT_DIR/.github/workflows/release.yml"
