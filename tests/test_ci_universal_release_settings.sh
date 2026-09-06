#!/usr/bin/env bash
# Regression test for universal GhosttyKit and Release build settings.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for file in \
  "$ROOT_DIR/.github/workflows/build-ghosttykit.yml" \
  "$ROOT_DIR/scripts/ensure-ghosttykit.sh" \
  "$ROOT_DIR/scripts/build-sign-upload.sh"
do
  if ! grep -Fq -- '-Dxcframework-target=universal' "$file"; then
    echo "FAIL: $file must build GhosttyKit with -Dxcframework-target=universal"
    exit 1
  fi
done

if ! grep -Fq -- 'url = https://github.com/mochiexists/ghostty.git' "$ROOT_DIR/.gitmodules"; then
  echo "FAIL: the ghostty submodule must use the fork that contains the pinned commit"
  exit 1
fi

for file in \
  "$ROOT_DIR/.github/workflows/build-ghosttykit.yml" \
  "$ROOT_DIR/scripts/download-prebuilt-ghosttykit.sh" \
  "$ROOT_DIR/scripts/ensure-ghosttykit.sh"
do
  if ! grep -Fq -- 'mochiexists/ghostty' "$file"; then
    echo "FAIL: $file must publish or download GhosttyKit from mochiexists/ghostty"
    exit 1
  fi
done

if ! grep -Fq -- '-Dsentry=false' "$ROOT_DIR/scripts/build-sign-upload.sh"; then
  echo "FAIL: build-sign-upload.sh must disable Ghostty native Sentry"
  exit 1
fi

if ! grep -Fq -- 'crashsubdir-cmux-crash-sentry-off-v1' "$ROOT_DIR/scripts/build-sign-upload.sh"; then
  echo "FAIL: build-sign-upload.sh must use the Sentry-disabled GhosttyKit cache flavor"
  exit 1
fi

if ! awk '
  /\/\* Release \*\// { in_release=1; next }
  in_release && /ONLY_ACTIVE_ARCH = YES;/ { saw_yes=1 }
  in_release && /ONLY_ACTIVE_ARCH = NO;/ { saw_no=1 }
  in_release && /name = Release;/ { in_release=0 }
  END { exit !(saw_no && !saw_yes) }
' "$ROOT_DIR/cmux.xcodeproj/project.pbxproj"; then
  echo "FAIL: Release configurations in project.pbxproj must use ONLY_ACTIVE_ARCH = NO"
  exit 1
fi

echo "PASS: GhosttyKit builds are universal, Sentry-disabled, and Release configs disable ONLY_ACTIVE_ARCH"
