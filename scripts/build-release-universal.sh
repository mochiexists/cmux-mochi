#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-release-universal.sh [--derived-data-path <path>] [--cloned-source-packages-dir-path <path>] [--appicon <name>]

Builds the unsigned universal Release app with the exact flags used by release
and CI release-build lanes.
EOF
}

DERIVED_DATA_PATH="build-universal"
CLONED_SOURCE_PACKAGES_DIR_PATH=""
APPICON_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data-path|--derivedDataPath)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a value" >&2
        usage >&2
        exit 2
      fi
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --cloned-source-packages-dir-path|--clonedSourcePackagesDirPath)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a value" >&2
        usage >&2
        exit 2
      fi
      CLONED_SOURCE_PACKAGES_DIR_PATH="$2"
      shift 2
      ;;
    --appicon)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a value" >&2
        usage >&2
        exit 2
      fi
      APPICON_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command=(
  xcodebuild
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -derivedDataPath "$DERIVED_DATA_PATH"
  -jobs 1
  -destination "generic/platform=macOS"
)

if [[ -n "$CLONED_SOURCE_PACKAGES_DIR_PATH" ]]; then
  command+=(-clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH")
fi

command+=(
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
  SWIFT_COMPILATION_MODE=singlefile
  CODE_SIGNING_ALLOWED=NO
)

if [[ -n "$APPICON_NAME" ]]; then
  command+=(ASSETCATALOG_COMPILER_APPICON_NAME="$APPICON_NAME")
fi

command+=(build)

CMUX_SKIP_ZIG_BUILD=1 "${command[@]}"
