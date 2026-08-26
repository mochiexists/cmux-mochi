#!/usr/bin/env bash
# Launch a tagged cmux iOS DEV build signed out by default and, when requested,
# pair it to the tagged Mac with a v3 DeviceLink code. DeviceLink carries no
# Stack bearer: the app enrolls a device key over pinned mutual TLS, persists
# that identity, and reconnects without an account.
#
# It reuses the app's existing DEBUG launch hooks:
#   CMUX_UITEST_MOCK_DATA=0                               -> real backend, not mock
#   CMUX_DOGFOOD_ATTACH_URL=<cmux-ios://attach?v=3...>    -> DeviceLink enrollment
# (sim env via SIMCTL_CHILD_*, device env via DEVICECTL_CHILD_*).
#
# Usage:
#   scripts/mobile-dev-launch.sh --tag grid [--simulator "iPhone 17"] [--attach|--no-attach] [--detach]
#   scripts/mobile-dev-launch.sh --tag grid --device [--device-id <id>] [--attach|--no-attach]
#   scripts/mobile-dev-launch.sh --tag grid --legacy-stack-attach --agent --attach
#
#   --attach   pair account-free with a fresh v3 DeviceLink code minted from
#              THIS tag's Mac debug socket. A physical-device code must contain
#              a non-loopback Tailscale route.
#   --ensure-mac  imply --attach and, before minting, enable the tagged Mac app's
#              pairing host + launch it if its debug socket is down. Lets a device
#              reload auto-pair with no separately-running Mac app.
#   --no-attach  launch signed out without pairing. Also cancels --ensure-mac.
#              When attach flags are repeated, the last flag wins.
#   --legacy-stack-attach
#              explicit compatibility mode: use the old Stack sign-in plus
#              target-specific legacy attach ticket (Iroh on physical devices).
#   --agent    legacy mode only: use the shared agent account.
#   --detach   simulator only: launch without attaching stdio, so the app keeps
#              running after this script exits.
#   --iroh-release-gate <automatic|relayOnly|directOnly>
#              simulator only: run the credential-free Iroh release-gate probe
#              after sign-in and attach.
#   --credentials-file <absolute-path>
#              load one 0600 credential file exclusively. Intended for an
#              isolated temporary production release-gate account.

set -euo pipefail

TAG=""
TARGET="simulator"          # simulator | device
SIMULATOR_NAME="iPhone 17"
SIMULATOR_ID=""             # exact booted sim UDID (wins over name when set)
DEVICE_ID=""
ATTACH=0
ENSURE_MAC=0
LEGACY_STACK_ATTACH=0
AGENT=0
DETACH=0
IROH_RELEASE_GATE_MODE=""
AUTH_CREDENTIALS_FILE=""
ATTACH_TTL_SECONDS="${CMUX_ATTACH_TTL_SECONDS:-600}"
ATTACH_MINT_MAX_ATTEMPTS="${CMUX_ATTACH_MINT_MAX_ATTEMPTS:-20}"

usage() { sed -n '2,36p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --simulator) TARGET="simulator"; SIMULATOR_NAME="${2:-}"; shift 2 ;;
    # Exact booted simulator UDID; wins over --simulator name so callers that
    # already resolved/installed onto a specific sim launch on THAT one.
    --simulator-id) TARGET="simulator"; SIMULATOR_ID="${2:-}"; shift 2 ;;
    --device) TARGET="device"; shift ;;
    --device-id) DEVICE_ID="${2:-}"; shift 2 ;;
    --attach) ATTACH=1; shift ;;
    --no-attach) ATTACH=0; ENSURE_MAC=0; shift ;;
    # --ensure-mac: before minting, enable the tagged Mac app's pairing host and
    # launch it if its debug socket is down, so --attach can mint without a
    # separately-running Mac app. Implies --attach.
    --ensure-mac) ENSURE_MAC=1; ATTACH=1; shift ;;
    --legacy-stack-attach) LEGACY_STACK_ATTACH=1; shift ;;
    --agent) AGENT=1; shift ;;
    --detach) DETACH=1; shift ;;
    --iroh-release-gate) IROH_RELEASE_GATE_MODE="${2:-}"; shift 2 ;;
    --credentials-file) AUTH_CREDENTIALS_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }
if [[ ! "$ATTACH_MINT_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CMUX_ATTACH_MINT_MAX_ATTEMPTS must be a positive integer" >&2
  exit 2
fi
if [[ "$DETACH" -eq 1 && "$TARGET" != "simulator" ]]; then
  echo "error: --detach is supported only with simulator launches" >&2
  usage >&2
  exit 2
fi
if [[ -n "$IROH_RELEASE_GATE_MODE" ]]; then
  LEGACY_STACK_ATTACH=1
  ATTACH=1
  if [[ "$TARGET" != "simulator" ]]; then
    echo "error: --iroh-release-gate is simulator-only" >&2
    exit 2
  fi
  case "$IROH_RELEASE_GATE_MODE" in
    automatic|relayOnly|directOnly) ;;
    *)
      echo "error: invalid --iroh-release-gate mode '$IROH_RELEASE_GATE_MODE'" >&2
      exit 2
      ;;
  esac
fi

# --- shared helpers / optional legacy credentials ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
# Fail before loading credentials or touching a simulator/device if the tag
# would collide with a fallback/reserved identity or exceed the cloud limit.
if ! cmux_attach_validate_dev_tag "$TAG"; then
  exit 2
fi
if [[ "$LEGACY_STACK_ATTACH" -eq 1 ]]; then
  if [[ -n "$AUTH_CREDENTIALS_FILE" ]]; then
    cmux_dev_secrets_load --credentials-file "$AUTH_CREDENTIALS_FILE" || exit $?
  elif [[ "$AGENT" -eq 1 ]]; then
    cmux_dev_secrets_load --agent || exit $?
  else
    cmux_dev_secrets_load || exit $?
  fi
elif [[ "$AGENT" -eq 1 || -n "$AUTH_CREDENTIALS_FILE" ]]; then
  echo "error: --agent and --credentials-file require --legacy-stack-attach" >&2
  exit 2
fi

# --- bundle id (matches ios/scripts/reload.sh sanitize_tag) ------------------
slug="$(cmux_attach__slug "$TAG")"
BUNDLE_ID="${CMUX_FORK_BUNDLE_ID}.ios.$slug"
if [[ "$TARGET" == "device" || -n "$IROH_RELEASE_GATE_MODE" ]]; then
  # The release gate runs in a simulator but must fail closed until the Mac can
  # mint an identity-only Iroh route. Reuse the physical-device ticket policy,
  # which polls for Iroh and never falls back to loopback.
  ATTACH_TARGET="physical_device"
else
  ATTACH_TARGET="simulator_injection"
fi

# --- DeviceLink pairing / explicit legacy attach ----------------------------
# PAIRING_URL stays empty unless pairing was explicitly requested, so a stale
# ambient CMUX_DOGFOOD_ATTACH_URL can NEVER auto-pair an unrequested launch
# (reload scripts that opt out simply leave ATTACH=0). The same DEBUG launch
# seam accepts both v3 DeviceLink and the explicit legacy compatibility URL.
PAIRING_URL=""
if [[ "$ATTACH" -eq 1 ]]; then
  ATTACH_SOCKET_READY=0
  ATTACH_MINT_STATUS=1
  if [[ "$ENSURE_MAC" -eq 1 ]]; then
    if [[ "$LEGACY_STACK_ATTACH" -eq 1 ]]; then
      cmux_attach_ensure_mac "$TAG" "$REPO_ROOT" "$ATTACH_TARGET" || true
    else
      cmux_attach_ensure_mac_devicelink "$TAG" "$REPO_ROOT" "$ATTACH_TARGET" || true
    fi
  fi
  # Always mint from THIS tag's socket for the selected launch target. Never
  # trust an ambient URL or the tag-agnostic QR server, either of which could
  # pair this app with another tagged Mac instance.
  if cmux_attach_mac_socket_ready "$TAG"; then
    ATTACH_SOCKET_READY=1
    if [[ "$LEGACY_STACK_ATTACH" -eq 1 ]]; then
      PAIRING_URL="$(cmux_attach_mint_url "$TAG" "$ATTACH_TTL_SECONDS" "$REPO_ROOT" "$ATTACH_TARGET" "$ATTACH_MINT_MAX_ATTEMPTS")" \
        || ATTACH_MINT_STATUS=$?
    else
      PAIRING_URL="$(cmux_attach_mint_devicelink_url "$TAG" "$ATTACH_TTL_SECONDS" "$REPO_ROOT" "$ATTACH_TARGET" "$ATTACH_MINT_MAX_ATTEMPTS")" \
        || ATTACH_MINT_STATUS=$?
    fi
    if [[ -n "$PAIRING_URL" ]]; then
      ATTACH_MINT_STATUS=0
    fi
  fi
  if [[ -z "$PAIRING_URL" ]]; then
    if [[ "$ATTACH_SOCKET_READY" -eq 0 ]]; then
      echo "error: tagged Mac '$TAG' is not running or its debug socket is not ready" >&2
      echo "error: start it and re-run with --ensure-mac" >&2
    elif [[ "$LEGACY_STACK_ATTACH" -eq 1 ]]; then
      if [[ "$ATTACH_TARGET" == "physical_device" && "$ATTACH_MINT_STATUS" -eq 2 ]]; then
        echo "error: tagged Mac '$TAG' advertised routes, but no encrypted Iroh route became ready" >&2
        echo "error: legacy Stack attach requires Iroh on a physical device" >&2
      else
        echo "error: could not mint a legacy attach ticket for '$TAG'" >&2
      fi
    else
      if [[ "$ATTACH_TARGET" == "physical_device" && "$ATTACH_MINT_STATUS" -eq 2 ]]; then
        echo "error: v3 DeviceLink code has no phone-reachable Tailscale route" >&2
      else
        echo "error: could not mint a v3 DeviceLink pairing code for '$TAG'" >&2
      fi
    fi
    exit 1
  fi
fi

# Never print the pairing URL: v3 carries a single-use enrollment capability,
# while legacy mode carries a bearer credential.
if [[ "$LEGACY_STACK_ATTACH" -eq 1 ]]; then
  SIGN_IN_ACCOUNT_LABEL="$CMUX_UITEST_STACK_EMAIL"
  [[ -z "$AUTH_CREDENTIALS_FILE" ]] || SIGN_IN_ACCOUNT_LABEL="[redacted]"
  echo "==> launching $BUNDLE_ID on $TARGET (legacy signed in as $SIGN_IN_ACCOUNT_LABEL${PAIRING_URL:+, auto-pairing})"
else
  echo "==> launching $BUNDLE_ID on $TARGET (no account${PAIRING_URL:+, DeviceLink pairing})"
fi

if [[ "$TARGET" == "simulator" ]]; then
  if [[ -n "$SIMULATOR_ID" ]]; then
    # Exact UDID the caller installed onto; do not re-resolve by name (multiple
    # booted sims can share a name across runtimes).
    SIM_UDID="$SIMULATOR_ID"
  else
    SIM_UDID="$(xcrun simctl list devices booted 2>/dev/null | grep -F "$SIMULATOR_NAME" | grep -oE '[0-9A-F-]{36}' | head -1)"
  fi
  if [[ -z "$SIM_UDID" ]]; then
    echo "error: simulator '${SIMULATOR_ID:-$SIMULATOR_NAME}' is not booted (boot it or pass --simulator <name>)" >&2
    exit 1
  fi
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  SIMULATOR_DEVICE_ID="$(
    cmux_attach_seed_simulator_device_id "$SIM_UDID" "$BUNDLE_ID"
  )"
  launch_args=(launch)
  if [[ "$DETACH" -ne 1 ]]; then
    launch_args+=(--console-pty)
  fi
  if [[ "$LEGACY_STACK_ATTACH" -eq 1 ]]; then
    SIMCTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
    SIMCTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
    SIMCTL_CHILD_CMUX_SIMULATOR_DEVICE_ID="$SIMULATOR_DEVICE_ID" \
    SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
    SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$PAIRING_URL" \
    SIMCTL_CHILD_CMUX_IROH_RELEASE_GATE_MODE="$IROH_RELEASE_GATE_MODE" \
    SIMCTL_CHILD_CMUX_IROH_RELEASE_GATE_SCENARIO="${CMUX_IROH_RELEASE_GATE_SCENARIO:-standard}" \
    SIMCTL_CHILD_CMUX_IROH_DISABLE_RELAY_CREDENTIAL_REFRESH="${CMUX_IROH_DISABLE_RELAY_CREDENTIAL_REFRESH:-0}" \
      xcrun simctl "${launch_args[@]}" "$SIM_UDID" "$BUNDLE_ID"
  else
    SIMCTL_CHILD_CMUX_SIMULATOR_DEVICE_ID="$SIMULATOR_DEVICE_ID" \
    SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
    SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$PAIRING_URL" \
      xcrun simctl "${launch_args[@]}" "$SIM_UDID" "$BUNDLE_ID"
  fi
else
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
      | awk '/iPhone/ && !/unavailable/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-Fa-f-]{36}$/){print $i; exit}}')"
  fi
  [[ -n "$DEVICE_ID" ]] || { echo "error: no connected iPhone found (pass --device-id)" >&2; exit 1; }
  # Child variables use the calling environment so pairing capabilities and,
  # only in explicit legacy mode, Stack credentials never appear in argv.
  if [[ "$LEGACY_STACK_ATTACH" -eq 1 ]]; then
    DEVICECTL_CHILD_CMUX_UITEST_STACK_EMAIL="$CMUX_UITEST_STACK_EMAIL" \
    DEVICECTL_CHILD_CMUX_UITEST_STACK_PASSWORD="$CMUX_UITEST_STACK_PASSWORD" \
    DEVICECTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
    DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$PAIRING_URL" \
      xcrun devicectl device process launch --terminate-existing \
        --device "$DEVICE_ID" "$BUNDLE_ID"
  else
    DEVICECTL_CHILD_CMUX_UITEST_MOCK_DATA="0" \
    DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL="$PAIRING_URL" \
      xcrun devicectl device process launch --terminate-existing \
        --device "$DEVICE_ID" "$BUNDLE_ID"
  fi
fi
