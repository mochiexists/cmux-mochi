#!/usr/bin/env bash
# Generate the fork's identity artifacts from fork-identity.json.
#
# The fork differs from upstream in a handful of identity values (app name,
# bundle id, URL scheme, update feed, signing). Patching those values into
# hundreds of files is what makes every upstream rebase expensive, so instead
# they live in ONE json file and are projected into:
#
#   config/ForkIdentity.xcconfig  build settings, referenced as $(CMUX_*) from
#                                 the Xcode project
#   scripts/fork-identity.env     shell-sourceable values for build, release,
#                                 and test scripts
#
# Both outputs are generated and committed, so a fresh clone builds without
# running anything, while --check proves they still match the source.
#
#   scripts/inject-fork-identity.sh [--channel stable|alpha]
#   scripts/inject-fork-identity.sh --check   # CI drift guard, writes nothing
#   scripts/inject-fork-identity.sh --scan    # find upstream identity that
#                                             # leaked back in after a rebase
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_JSON="$REPO_ROOT/fork-identity.json"
RENDERER="$REPO_ROOT/scripts/render_fork_identity.py"
XCCONFIG_OUT="$REPO_ROOT/config/ForkIdentity.xcconfig"
ENV_OUT="$REPO_ROOT/scripts/fork-identity.env"

CHANNEL="stable"
MODE="write"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --check)   MODE="check";     shift ;;
    --scan)    MODE="scan";      shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$SOURCE_JSON" ]]; then
  echo "error: missing $SOURCE_JSON" >&2
  exit 1
fi

# --scan reports any upstream identity string still present in tracked files.
# After a rebase, this is how we find identity that reverted to upstream's.
if [[ "$MODE" == "scan" ]]; then
  upstream_bundle="$(python3 "$RENDERER" --source "$SOURCE_JSON" --print upstream_bundle_id)"
  echo "Scanning tracked files for upstream identity: $upstream_bundle"
  if git -C "$REPO_ROOT" grep -n --fixed-strings "$upstream_bundle" -- \
      ':!fork-identity.json' ':!scripts/inject-fork-identity.sh'; then
    echo >&2
    echo "error: upstream identity is still present in the files listed above" >&2
    exit 1
  fi
  echo "clean: no upstream identity found in tracked files"
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT
  python3 "$RENDERER" \
    --source "$SOURCE_JSON" --channel "$CHANNEL" \
    --xcconfig "$staging/ForkIdentity.xcconfig" --env "$staging/fork-identity.env"

  status=0
  for pair in "$XCCONFIG_OUT:$staging/ForkIdentity.xcconfig" "$ENV_OUT:$staging/fork-identity.env"; do
    committed="${pair%%:*}"
    expected="${pair##*:}"
    if [[ ! -f "$committed" ]]; then
      echo "error: ${committed#"$REPO_ROOT"/} is missing; run scripts/inject-fork-identity.sh" >&2
      status=1
    elif ! diff -u "$committed" "$expected" >/dev/null; then
      echo "error: ${committed#"$REPO_ROOT"/} is stale; run scripts/inject-fork-identity.sh" >&2
      diff -u "$committed" "$expected" >&2 || true
      status=1
    else
      echo "ok: ${committed#"$REPO_ROOT"/}"
    fi
  done
  exit "$status"
fi

python3 "$RENDERER" \
  --source "$SOURCE_JSON" --channel "$CHANNEL" \
  --xcconfig "$XCCONFIG_OUT" --env "$ENV_OUT"

echo "wrote: ${XCCONFIG_OUT#"$REPO_ROOT"/}"
echo "wrote: ${ENV_OUT#"$REPO_ROOT"/}"
