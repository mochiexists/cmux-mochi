#!/usr/bin/env bash
# Guard Developer ID signing setup against self-hosted runner keychain drift.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

check_signing_keychain_setup() {
  local file="$1"

  if ! awk '
    /security import \/tmp\/cert\.p12/ { saw_leaf=1 }
    /DEVELOPER_ID_CA_CERTS=\/tmp\/developer-id-ca-certs\.pem/ { saw_ca_file=1 }
    /security find-certificate -a -c "Developer ID Certification Authority"/ { saw_ca_lookup=1 }
    /security import "\$DEVELOPER_ID_CA_CERTS" -k build\.keychain -t cert/ { saw_ca_import=1 }
    /security list-keychains -d user -s build\.keychain "\$HOME\/Library\/Keychains\/login\.keychain-db"/ { saw_login_search=1 }
    END { exit !(saw_leaf && saw_ca_file && saw_ca_lookup && saw_ca_import && saw_login_search) }
  ' "$file"; then
    echo "FAIL: $(basename "$file") must import Developer ID CA intermediates and keep login keychain searchable for codesign"
    exit 1
  fi

  echo "PASS: $(basename "$file") prepares Developer ID signing chain for self-hosted runners"
}

check_signing_keychain_setup "$ROOT_DIR/.github/workflows/nightly.yml"
check_signing_keychain_setup "$ROOT_DIR/.github/workflows/release.yml"
