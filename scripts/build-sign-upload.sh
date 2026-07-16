#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, create DMG, generate appcast, and upload to GitHub release.
# Usage: ./scripts/build-sign-upload.sh <tag> [--allow-overwrite]
# Requires: source ~/.secrets/cmuxterm.env && export SPARKLE_PRIVATE_KEY

usage() {
  cat <<'EOF'
Usage: ./scripts/build-sign-upload.sh <tag> [--allow-overwrite]

Options:
  --allow-overwrite   Permit replacing existing release assets for the same tag.
                      Use only for emergency rerolls.
  --dry-run           Build, sign, notarize, staple and Gatekeeper-verify, but
                      do NOT create or upload a GitHub release. Validates the
                      local pipeline with no published assets and no Sparkle
                      feed change.
EOF
}

ALLOW_OVERWRITE="false"
DRY_RUN="false"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-overwrite)
      ALLOW_OVERWRITE="true"
      shift
      ;;
    --dry-run)
      # Build, sign, notarize, staple and verify locally, but do NOT create or
      # upload a GitHub release. For validating the local release pipeline with
      # zero outward effect (no published assets, no Sparkle feed change).
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

TAG="$1"
# Fork (cmux Mochi) signing identity. The fork signs with its own Developer ID
# Application cert (Atlas Codes LTD, Team 599WAZ6282), not upstream cmux's.
# Override with SIGN_HASH=... if the cert is ever rotated.
SIGN_HASH="${SIGN_HASH:-33FD69D8D96F40228978FFA0F36771AA007DF335}"
# notarytool keychain profile created via `xcrun notarytool store-credentials`.
NOTARY_PROFILE="${NOTARY_PROFILE:-cmux-mochi-notary}"
ENTITLEMENTS="cmux.release.entitlements"
APP_PATH="build/Build/Products/Release/cmux Mochi.app"
GHOSTTYKIT_CRASH_REPORT_SUBDIR="cmux/crash"

# --- Pre-flight ---
# Fork secrets file (Sparkle keys). Falls back to the legacy upstream name.
SECRETS_ENV="${SECRETS_ENV:-$HOME/.secrets/cmux-mochi.env}"
[ -f "$SECRETS_ENV" ] || SECRETS_ENV="$HOME/.secrets/cmuxterm.env"
# shellcheck source=/dev/null
source "$SECRETS_ENV"
export SPARKLE_PRIVATE_KEY
for tool in zig xcodebuild create-dmg xcrun codesign ditto gh; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done
[ -n "${SPARKLE_PRIVATE_KEY:-}" ] || { echo "MISSING: SPARKLE_PRIVATE_KEY (expected in $SECRETS_ENV)" >&2; exit 1; }
security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_HASH" \
  || { echo "MISSING: signing identity $SIGN_HASH not in keychain" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "MISSING: notarytool keychain profile '$NOTARY_PROFILE' (run: xcrun notarytool store-credentials)" >&2; exit 1; }
echo "Pre-flight checks passed"

# --- Build GhosttyKit ---
echo "Building GhosttyKit..."
rm -rf GhosttyKit.xcframework ghostty/macos/GhosttyKit.xcframework
(
  cd ghostty
  zig build -Dcrash-report-subdir="$GHOSTTYKIT_CRASH_REPORT_SUBDIR" -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast
)
cp -R ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework

# --- Build app (Release, unsigned) ---
echo "Building app..."
rm -rf build/
./scripts/build-release-universal.sh --derived-data-path build
echo "Build succeeded"

# --- Build + install the universal Ghostty CLI (theme picker) helper ---
# xcodebuild does not produce this helper; CI builds it in a separate job and
# injects it into the bundle. Replicate that here so the app is complete.
echo "Building Ghostty CLI helper..."
GHOSTTY_HELPER_BUILD="build/ghostty-cli-helper/ghostty"
mkdir -p "$(dirname "$GHOSTTY_HELPER_BUILD")"
./scripts/build-ghostty-cli-helper.sh --universal --output "$GHOSTTY_HELPER_BUILD"
./scripts/install-prebuilt-ghostty-cli-helper.sh "$GHOSTTY_HELPER_BUILD" "$APP_PATH"

HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
if [ ! -x "$HELPER_PATH" ]; then
  echo "Ghostty theme picker helper not found at $HELPER_PATH" >&2
  exit 1
fi

# --- Inject Sparkle keys ---
echo "Injecting Sparkle keys..."
SPARKLE_PUBLIC_KEY_DERIVED=$(swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY")
APP_PLIST="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY_DERIVED" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml" "$APP_PLIST"
echo "Sparkle keys injected"

# --- Codesign ---
echo "Codesigning..."
./scripts/sign-cmux-bundle.sh "$APP_PATH" "$ENTITLEMENTS" "$SIGN_HASH"
echo "Codesign verified"

# --- Notarize app ---
echo "Notarizing app..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" cmux-notary.zip
xcrun notarytool submit cmux-notary.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f cmux-notary.zip
echo "App notarized"

# --- Create and notarize DMG ---
echo "Creating DMG..."
rm -f cmux-macos.dmg cmux*.dmg
create-dmg --no-code-sign "$APP_PATH" ./
CREATED_DMG="$(find . -maxdepth 1 -name 'cmux*.dmg' | head -n 1)"
if [ -z "$CREATED_DMG" ]; then
  echo "Failed to locate created DMG for $APP_PATH" >&2
  exit 1
fi
mv "$CREATED_DMG" cmux-macos.dmg
/usr/bin/codesign --force --timestamp --sign "$SIGN_HASH" cmux-macos.dmg
/usr/bin/codesign --verify --verbose=2 cmux-macos.dmg
echo "Notarizing DMG..."
xcrun notarytool submit cmux-macos.dmg --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple cmux-macos.dmg
xcrun stapler validate cmux-macos.dmg
echo "DMG notarized"

# --- Gatekeeper assessment (proves the signed+notarized+stapled app passes) ---
echo "Gatekeeper assessment..."
spctl --assess --type execute --verbose=4 "$APP_PATH"

# --- Generate Sparkle appcast ---
echo "Generating appcast..."
./scripts/sparkle_generate_appcast.sh cmux-macos.dmg "$TAG" appcast.xml

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "DRY RUN complete — built, signed, notarized, stapled and Gatekeeper-verified."
  echo "Artifacts left in place (not uploaded): $(pwd)/cmux-macos.dmg, $(pwd)/appcast.xml"
  echo "Re-run without --dry-run to publish release $TAG."
  exit 0
fi

# --- Create GitHub release (if needed) and upload ---
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists"
  EXISTING_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' || true)"
  HAS_CONFLICTING_ASSET="false"
  for asset in cmux-macos.dmg appcast.xml; do
    if printf '%s\n' "$EXISTING_ASSETS" | grep -Fxq "$asset"; then
      HAS_CONFLICTING_ASSET="true"
      break
    fi
  done

  if [[ "$HAS_CONFLICTING_ASSET" == "true" && "$ALLOW_OVERWRITE" != "true" ]]; then
    echo "ERROR: Refusing to overwrite signed release assets for existing tag $TAG." >&2
    echo "Use a new tag, or rerun with --allow-overwrite for an emergency reroll." >&2
    exit 1
  fi

  if [[ "$ALLOW_OVERWRITE" == "true" ]]; then
    echo "Uploading with overwrite enabled for existing release $TAG..."
    gh release upload "$TAG" cmux-macos.dmg appcast.xml --clobber
  else
    echo "Uploading to existing release $TAG..."
    gh release upload "$TAG" cmux-macos.dmg appcast.xml
  fi
else
  echo "Creating release $TAG and uploading..."
  gh release create "$TAG" cmux-macos.dmg appcast.xml --title "$TAG" --notes "See CHANGELOG.md for details"
fi

# --- Verify ---
gh release view "$TAG"

# --- Update Homebrew cask (skip for nightlies) ---
# Fork (cmux Mochi): gated off by default until the mochiexists tap exists.
# Opt in with UPDATE_HOMEBREW=1.
if [[ "${UPDATE_HOMEBREW:-0}" == "1" && "$TAG" != *"-nightly"* ]]; then
  VERSION="${TAG#v}"
  DMG_SHA256=$(shasum -a 256 cmux-macos.dmg | cut -d' ' -f1)
  echo "Updating homebrew cask to $VERSION (SHA: $DMG_SHA256)..."
  CASK_FILE="homebrew-cmux/Casks/cmux.rb"
  if [ -f "$CASK_FILE" ]; then
    cat > "$CASK_FILE" << CASKEOF
cask "cmux" do
  version "${VERSION}"
  sha256 "${DMG_SHA256}"

  url "https://github.com/mochiexists/cmux-mochi/releases/download/v#{version}/cmux-macos.dmg"
  name "cmux"
  desc "Lightweight native macOS terminal with vertical tabs for AI coding agents"
  homepage "https://github.com/mochiexists/cmux-mochi"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "cmux.app"
  binary "#{appdir}/cmux.app/Contents/Resources/bin/cmux"

  zap trash: [
    "~/Library/Application Support/cmux",
    "~/Library/Caches/cmux",
    "~/Library/Preferences/com.cmux-mochi.plist",
  ]
end
CASKEOF
    cd homebrew-cmux
    git add Casks/cmux.rb
    if git diff --staged --quiet; then
      echo "Homebrew cask already up to date"
    else
      git commit -m "Update cmux to ${VERSION}"
      git push
      echo "Homebrew cask updated"
    fi
    cd ..
  else
    echo "WARNING: homebrew-cmux submodule not found, skipping cask update"
  fi
fi

# --- Cleanup ---
rm -rf build/ cmux-macos.dmg appcast.xml
echo ""
echo "=== Release $TAG complete ==="
say "cmux release complete"
