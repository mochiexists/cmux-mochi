#!/usr/bin/env bash
# Regression test for the universal nightly macOS track.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

if grep -Eq '^  push:' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must be ad-hoc only; push trigger should stay disabled"
  exit 1
fi

if ! grep -Fq 'workflow_dispatch:' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must keep a manual workflow_dispatch trigger"
  exit 1
fi

if ! awk '
  /^      runner:/ { in_runner=1; next }
  in_runner && /^      [^[:space:]]/ { in_runner=0 }
  in_runner && /default: m4-signing-runner/ { saw_default=1 }
  in_runner && /- m4-signing-runner/ { saw_m4=1 }
  in_runner && /- hosted-macos-15/ { saw_hosted=1 }
  END { exit !(saw_default && saw_m4 && saw_hosted) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must expose an M4-default runner toggle with a hosted macOS 15 fallback"
  exit 1
fi

if ! grep -Fq '["self-hosted","cmux-mochi-m4pro"]' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly M4 lane must target the Mochi self-hosted signing runner label"
  exit 1
fi

if ! grep -Fq "vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15'" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly hosted lane must keep the repo-variable macOS 15 fallback"
  exit 1
fi

if ! awk '
  /^      - name: Build universal nightly app and Ghostty CLI helper \(Release\)/ { in_universal=1; next }
  in_universal && /^      - name:/ { in_universal=0 }
  in_universal && /\.\/scripts\/build-release-universal\.sh/ { saw_build_script=1 }
  in_universal && /--appicon AppIcon-Nightly/ { saw_appicon=1 }
  END {
    exit !(saw_build_script && saw_appicon)
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must use the shared universal release build script with the nightly icon"
  exit 1
fi

if ! awk '
  /^      - name: Build universal nightly app and Ghostty CLI helper \(Release\)/ { in_helper=1; next }
  in_helper && /^      - name:/ { in_helper=0 }
  in_helper && /build-ghostty-cli-helper\.sh --universal/ { saw_build=1 }
  in_helper && /helper missing arm64 slice/ { saw_arm64_assert=1 }
  in_helper && /helper missing x86_64 slice/ { saw_x86_assert=1 }
  in_helper && /wait "\$HELPER_PID"/ { saw_wait=1 }
  in_helper && /cat "\$HELPER_LOG"/ { saw_log=1 }
  END { exit !(saw_build && saw_arm64_assert && saw_x86_assert && saw_wait && saw_log) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must build and verify the real universal Ghostty helper alongside the app build"
  exit 1
fi

if ! awk '
  /^      - name: Inject universal Ghostty CLI helper/ { in_inject=1; next }
  in_inject && /^      - name:/ { in_inject=0 }
  in_inject && /APP_DIR="build-universal\/Build\/Products\/Release\/cmux Mochi\.app"/ { saw_mochi_app=1 }
  in_inject && /install -m 755 \/tmp\/cmux-ghostty-helper-universal "\$DEST"/ { saw_install=1 }
  END { exit !(saw_mochi_app && saw_install) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must inject the verified universal Ghostty helper into the built Mochi app"
  exit 1
fi

if ! awk '
  /^      - name: Verify nightly binary architectures/ { in_verify=1; next }
  in_verify && /^      - name:/ { in_verify=0 }
  in_verify && /cmux Mochi\.app\/Contents\/MacOS\/cmux Mochi/ { saw_mochi_binary=1 }
  in_verify && /lipo -archs "\$APP_BINARY"/ { saw_app=1 }
  in_verify && /lipo -archs "\$CLI_BINARY"/ { saw_cli=1 }
  in_verify && /lipo -archs "\$HELPER_BINARY"/ { saw_helper=1 }
  in_verify && /\[\[ "\$APP_ARCHS" == \*arm64\* && "\$APP_ARCHS" == \*x86_64\* \]\]/ { saw_app_assert=1 }
  in_verify && /\[\[ "\$CLI_ARCHS" == \*arm64\* && "\$CLI_ARCHS" == \*x86_64\* \]\]/ { saw_cli_assert=1 }
  in_verify && /\[\[ "\$HELPER_ARCHS" == \*arm64\* && "\$HELPER_ARCHS" == \*x86_64\* \]\]/ { saw_helper_assert=1 }
  END { exit !(saw_mochi_binary && saw_app && saw_cli && saw_helper && saw_app_assert && saw_cli_assert && saw_helper_assert) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must verify universal app, CLI, and helper slices from the built Mochi app with lipo"
  exit 1
fi

if ! awk '
  /^      - name: Inject nightly identities and metadata/ { in_inject=1; next }
  in_inject && /^      - name:/ { in_inject=0 }
  in_inject && /cmux Mochi\.app\/Contents\/Info\.plist/ { saw_mochi_plist=1 }
  in_inject && /mv "\$app_dir\/cmux Mochi\.app" "\$app_dir\/cmux Mochi NIGHTLY\.app"/ { saw_rename=1 }
  END { exit !(saw_mochi_plist && saw_rename) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly identity injection must mutate and rename the built Mochi app into the NIGHTLY app"
  exit 1
fi

if ! grep -Fq 'bundle ID `com.cmux-mochi.nightly`' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must publish the unified nightly bundle ID"
  exit 1
fi

if ! grep -Fq 'cp appcast.xml appcast-universal.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must keep the compatibility appcast-universal.xml feed"
  exit 1
fi

if ! grep -Fq './scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" nightly appcast.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must generate the unified nightly appcast"
  exit 1
fi

if ! grep -Fq 'https://github.com/mochiexists/cmux-mochi/releases/download/nightly/appcast.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly app must use the fork GitHub Release appcast as its Sparkle feed"
  exit 1
fi

if grep -Fq 'files.cmux.com' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must not publish or point Sparkle at files.cmux.com"
  exit 1
fi

if ! grep -Fq "core.setOutput('should_publish', isMainRef ? 'true' : 'false');" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly decide step must expose should_publish based on whether the ref is main"
  exit 1
fi

if ! awk '
  /^      - name: Upload branch nightly artifacts/ { in_upload=1; next }
  in_upload && /^      - name:/ { in_upload=0 }
  in_upload && /if: needs\.decide\.outputs\.should_publish != '\''true'\''/ { saw_if=1 }
  in_upload && /uses: actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7/ { saw_upload=1 }
  in_upload && /cmux-nightly-macos\*\.dmg/ { saw_arm_artifacts=1 }
  in_upload && /appcast-universal\.xml/ { saw_universal_appcast=1 }
  END { exit !(saw_if && saw_upload && saw_arm_artifacts && saw_universal_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: non-main nightly runs must upload nightly artifacts and compatibility appcasts"
  exit 1
fi

if ! awk '
  /^      - name: Move nightly tag to built commit/ { in_move=1; next }
  in_move && /^      - name:/ { in_move=0 }
  in_move && /if: needs\.decide\.outputs\.should_publish == '\''true'\''/ { saw_move_if=1 }
  END { exit !saw_move_if }
' "$WORKFLOW_FILE"; then
  echo "FAIL: moving the nightly tag must be gated to main nightly publishes"
  exit 1
fi

if ! awk '
  /^      - name: Publish nightly release assets/ { in_publish=1; next }
  in_publish && /^      - name:/ { in_publish=0 }
  in_publish && /if: needs\.decide\.outputs\.should_publish == '\''true'\''/ { saw_publish_if=1 }
  in_publish && /cmux-nightly-macos-\$\{\{ github\.run_id \}\}\*\.dmg/ { saw_immutable=1 }
  in_publish && /cmux-nightly-macos\.dmg/ { saw_stable=1 }
  in_publish && /appcast-universal\.xml/ { saw_universal_appcast=1 }
  END { exit !(saw_publish_if && saw_immutable && saw_stable && saw_universal_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: main nightly publish must include immutable/stable assets and compatibility appcast"
  exit 1
fi

echo "PASS: nightly workflow keeps the universal nightly track guarded"
