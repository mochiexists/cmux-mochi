#!/usr/bin/env bash
# Wait until codesign can really sign with IDENTITY before signing the bundle.
#
# Usage: scripts/ci/await-codesign-identity.sh <keychain> <identity> [attempts]
#
# `security list-keychains -d user -s <keychain>` swaps the user search list,
# but trustd/securityd observe the new list asynchronously. A codesign issued in
# the same instant can still evaluate the signer against the OLD search list, in
# which the freshly imported Developer ID intermediates do not exist, and fails
# with "unable to build chain to self-signed root" + errSecInternalComponent
# (trustd: "Trust evaluate failure: [leaf MissingIntermediate]"). Seen on the
# M4 Pro signing runner, nightly run 34533549785, 2026-09-10. Probing a scratch
# binary until it signs closes the window without touching the real bundle.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <keychain> <identity> [attempts]" >&2
  exit 2
fi

KEYCHAIN="$1"
IDENTITY="$2"
ATTEMPTS="${3:-20}"
DELAY_SECONDS=1

PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT
cp /usr/bin/true "$PROBE_DIR/probe"

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
  if output="$(/usr/bin/codesign --force --options runtime --timestamp=none \
      --sign "$IDENTITY" "$PROBE_DIR/probe" 2>&1)"; then
    echo "codesign identity ready after $attempt attempt(s)"
    exit 0
  fi
  echo "codesign readiness attempt $attempt/$ATTEMPTS failed: $output" >&2
  sleep "$DELAY_SECONDS"
done

echo "error: codesign never became ready with the identity in $KEYCHAIN" >&2
security list-keychains -d user >&2 || true
security find-identity -v -p codesigning "$KEYCHAIN" >&2 || true
exit 1
