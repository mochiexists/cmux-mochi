#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/cmux.xcodeproj"
cat > "$TMP_DIR/cmux.xcodeproj/project.pbxproj" <<'PBXPROJ'
MARKETING_VERSION = 0.64.150;
CURRENT_PROJECT_VERSION = 90;
PBXPROJ

cat > "$TMP_DIR/appcast.xml" <<'APPCAST'
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>106</sparkle:version>
      <sparkle:shortVersionString>0.64.161</sparkle:shortVersionString>
    </item>
  </channel>
</rss>
APPCAST

(
  cd "$TMP_DIR"
  CMUX_LATEST_APPCAST_URL="file://$TMP_DIR/appcast.xml" "$ROOT_DIR/scripts/bump-version.sh" >/tmp/cmux-bump-version-policy.log
)

if ! grep -Fq "MARKETING_VERSION = 0.64.162;" "$TMP_DIR/cmux.xcodeproj/project.pbxproj"; then
  echo "FAIL: default bump should patch from latest published appcast version" >&2
  cat /tmp/cmux-bump-version-policy.log >&2
  exit 1
fi

if ! grep -Fq "CURRENT_PROJECT_VERSION = 107;" "$TMP_DIR/cmux.xcodeproj/project.pbxproj"; then
  echo "FAIL: build number should increment from latest published appcast build" >&2
  cat /tmp/cmux-bump-version-policy.log >&2
  exit 1
fi

echo "PASS: bump-version defaults to fork patch releases from latest appcast baseline"
