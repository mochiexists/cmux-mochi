#!/usr/bin/env bash
set -euo pipefail

# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project.
# Usage:
#   ./scripts/bump-version.sh           # Auto-bump patch (0.64.161 -> 0.64.162)
#   ./scripts/bump-version.sh 0.16.0    # Set specific version
#   ./scripts/bump-version.sh patch     # Bump patch (0.15.0 -> 0.15.1)
#   ./scripts/bump-version.sh minor     # Bump minor (0.15.0 -> 0.16.0)
#   ./scripts/bump-version.sh major     # Bump major (0.15.0 -> 1.0.0)

PROJECT_FILE="cmux.xcodeproj/project.pbxproj"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from repo root." >&2
  exit 1
fi

# Get current versions
CURRENT_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
BASE_MARKETING="$CURRENT_MARKETING"
MIN_BUILD="$CURRENT_BUILD"

echo "Current: MARKETING_VERSION=$CURRENT_MARKETING, CURRENT_PROJECT_VERSION=$CURRENT_BUILD"

# Keep Sparkle versions monotonic with the latest published stable appcast.
# If local versions have fallen behind due merges/rebases, auto-correct upward.
LATEST_APPCAST_URL="${CMUX_LATEST_APPCAST_URL:-https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml}"
LATEST_RELEASE_APPCAST="$(
  curl -fsSL --max-time 8 "$LATEST_APPCAST_URL" 2>/dev/null \
    || true
)"
LATEST_RELEASE_BUILD="$(printf "%s" "$LATEST_RELEASE_APPCAST" | sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' | head -n1)"
LATEST_RELEASE_MARKETING="$(printf "%s" "$LATEST_RELEASE_APPCAST" | sed -n 's#.*<sparkle:shortVersionString>\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)</sparkle:shortVersionString>.*#\1#p' | head -n1)"
if [[ "$LATEST_RELEASE_BUILD" =~ ^[0-9]+$ ]]; then
  if (( LATEST_RELEASE_BUILD > MIN_BUILD )); then
    MIN_BUILD="$LATEST_RELEASE_BUILD"
  fi
  echo "Latest release appcast build: $LATEST_RELEASE_BUILD"
else
  echo "Latest release appcast build: unavailable (continuing with local build baseline)"
fi
if [[ "$LATEST_RELEASE_MARKETING" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  highest="$(printf "%s\n%s\n" "$CURRENT_MARKETING" "$LATEST_RELEASE_MARKETING" | sort -V | tail -n1)"
  if [[ "$highest" != "$CURRENT_MARKETING" ]]; then
    BASE_MARKETING="$LATEST_RELEASE_MARKETING"
  fi
  echo "Latest release marketing version: $LATEST_RELEASE_MARKETING"
else
  echo "Latest release marketing version: unavailable (continuing with local marketing baseline)"
fi

# Parse current marketing version
IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_MARKETING"

# Determine new marketing version
if [[ $# -eq 0 ]] || [[ "$1" == "patch" ]]; then
  NEW_MARKETING="$MAJOR.$MINOR.$((PATCH + 1))"
elif [[ "$1" == "minor" ]]; then
  NEW_MARKETING="$MAJOR.$((MINOR + 1)).0"
elif [[ "$1" == "major" ]]; then
  NEW_MARKETING="$((MAJOR + 1)).0.0"
elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  NEW_MARKETING="$1"
else
  echo "Usage: $0 [version|minor|patch|major]" >&2
  echo "  version: specific version like 0.16.0" >&2
  echo "  patch: bump patch version (default for the Mochi fork)" >&2
  echo "  minor: bump minor version for an explicit upstream-base jump" >&2
  echo "  major: bump major version" >&2
  exit 1
fi

# Always increment build number, and never go backwards relative to published releases.
NEW_BUILD=$((MIN_BUILD + 1))

echo "New:     MARKETING_VERSION=$NEW_MARKETING, CURRENT_PROJECT_VERSION=$NEW_BUILD"

# Update project file
sed -i '' "s/MARKETING_VERSION = $CURRENT_MARKETING;/MARKETING_VERSION = $NEW_MARKETING;/g" "$PROJECT_FILE"
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PROJECT_FILE"

# Verify
UPDATED_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
UPDATED_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')

if [[ "$UPDATED_MARKETING" != "$NEW_MARKETING" ]] || [[ "$UPDATED_BUILD" != "$NEW_BUILD" ]]; then
  echo "Error: Version update failed!" >&2
  exit 1
fi

echo "Updated $PROJECT_FILE successfully."
