#!/usr/bin/env bash
# Guard release/nightly provenance attestation against transient Sigstore/Rekor
# network failures without making release publication depend on Sigstore uptime.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTION='actions/attest-build-provenance@a2bbfa25375fe432b6a289bc6b6cd05ecd0c4c32'

check_attestation_retry() {
  local file="$1"
  local first_step="$2"
  local first_id="$3"
  local retry_step="$4"
  local retry_id="$5"
  local warning_step="$6"
  local subject_marker="$7"

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

  if ! awk -v retry_step="$retry_step" -v retry_id="$retry_id" -v first_id="$first_id" -v action="$ACTION" -v subject="$subject_marker" '
    $0 ~ "^[[:space:]]*- name: " retry_step "$" { in_step=1; next }
    in_step && /^      - name:/ { in_step=0 }
    in_step && $0 ~ "id: " retry_id "$" { saw_id=1 }
    in_step && index($0, "steps." first_id ".outcome == '\''failure'\''") { saw_outcome=1 }
    in_step && /continue-on-error:[[:space:]]*true/ { saw_continue=1 }
    in_step && index($0, "uses: " action) { saw_action=1 }
    in_step && index($0, subject) { saw_subject=1 }
    END { exit !(saw_id && saw_outcome && saw_continue && saw_action && saw_subject) }
  ' "$file"; then
    echo "FAIL: $(basename "$file") retry attestation step must run only after first failure, be best-effort, and keep the expected subject"
    exit 1
  fi

  if ! awk -v warning_step="$warning_step" -v retry_id="$retry_id" '
    $0 ~ "^[[:space:]]*- name: " warning_step "$" { in_step=1; next }
    in_step && /^      - name:/ { in_step=0 }
    in_step && index($0, "steps." retry_id ".outcome == '\''failure'\''") { saw_outcome=1 }
    in_step && /::warning::/ { saw_warning=1 }
    END { exit !(saw_outcome && saw_warning) }
  ' "$file"; then
    echo "FAIL: $(basename "$file") must emit a workflow warning when retry attestation fails"
    exit 1
  fi

  echo "PASS: $(basename "$file") retries remote daemon asset attestation without blocking publication"
}

check_attestation_retry \
  "$ROOT_DIR/.github/workflows/nightly.yml" \
  "Attest remote daemon nightly assets" \
  "attest-remote-daemon-nightly-assets" \
  "Retry remote daemon nightly asset attestation" \
  "retry-remote-daemon-nightly-asset-attestation" \
  "Warn if remote daemon nightly asset attestation failed" \
  'remote-daemon-assets/cmuxd-remote-manifest-${{ env.NIGHTLY_BUILD }}.json'

check_attestation_retry \
  "$ROOT_DIR/.github/workflows/release.yml" \
  "Attest remote daemon release assets" \
  "attest-remote-daemon-release-assets" \
  "Retry remote daemon release asset attestation" \
  "retry-remote-daemon-release-asset-attestation" \
  "Warn if remote daemon release asset attestation failed" \
  "remote-daemon-assets/cmuxd-remote-manifest.json"
