#!/usr/bin/env bash
# Import Apple's Worldwide Developer Relations (WWDR) intermediate certificate
# into an ephemeral signing keychain so an Apple Distribution identity can build
# a complete chain on every runner.
#
# This is the iOS counterpart to import-apple-developer-id-intermediates.sh:
# Developer ID certificates (macOS notarization) chain through the Developer ID
# CA, while Apple Distribution certificates (iOS TestFlight / App Store) chain
# through WWDR G3. Importing the wrong one leaves `security find-identity -v`
# reporting "0 valid identities found" even though the key and certificate both
# imported successfully.
#
# GitHub-hosted macOS runners ship WWDR in the System keychain, so this only
# becomes load-bearing on self-hosted runners -- and on any runner where the
# signing step replaces the keychain search list with just its own keychain.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <keychain>" >&2
  exit 2
fi

KEYCHAIN="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/apple-developer-id-certs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Prefer the vendored copy committed to the repo so signing never depends on a
# live network fetch from Apple, matching the Developer ID script's rationale.
NAME="AppleWWDRCAG3"
URL="https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
VENDORED="$VENDOR_DIR/$NAME.cer"

if [[ -s "$VENDORED" ]]; then
  CERT_PATH="$VENDORED"
else
  echo "Vendored $NAME.cer not found at $VENDORED; downloading from $URL" >&2
  CERT_PATH="$TMP_DIR/$NAME.cer"
  curl \
    --fail \
    --location \
    --retry 3 \
    --connect-timeout 20 \
    --max-time 120 \
    --silent \
    --show-error \
    "$URL" \
    --output "$CERT_PATH"
fi

security add-certificates -k "$KEYCHAIN" "$CERT_PATH"

IMPORTED_COUNT="$(
  security find-certificate -c "Apple Worldwide Developer Relations Certification Authority" -a -p "$KEYCHAIN" \
    | awk '/END CERTIFICATE/ { count++ } END { print count + 0 }'
)"

if [[ "$IMPORTED_COUNT" -lt 1 ]]; then
  echo "Expected the WWDR intermediate certificate in $KEYCHAIN; found $IMPORTED_COUNT" >&2
  exit 1
fi

echo "Imported Apple WWDR intermediate into $KEYCHAIN"
