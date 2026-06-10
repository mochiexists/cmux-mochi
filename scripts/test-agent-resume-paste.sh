#!/usr/bin/env bash
# End-to-end test for the agent resume-paste-on-quit feature, driven entirely
# through the cmux socket control interface (no manual interaction).
#
# It launches a real agent (codex or claude) in a fresh terminal surface of a
# tagged dev build, runs one turn so the session registers, quits the agent at
# the prompt, and asserts that the un-run resume command (`<agent> resume <id>`)
# was pre-typed into the shell.
#
# Prereqs:
#   - A tagged dev build is running: ./scripts/reload.sh --tag <tag> --launch
#   - For codex: a build with the ThreadUnsubscribe hook event
#       (ovm use codex dev:mochi-thread-unsubscribe-resume-...) and codex hooks
#       installed (cmux hooks codex install) so ThreadUnsubscribe -> session-end.
#
# Usage:
#   scripts/test-agent-resume-paste.sh [--tag <tag>] [--agent codex|claude|both]
#
# Exit code 0 = all requested agents pasted the correct resume command.
#
# Note: codex is reliable. claude (TUI) is best-effort — it only offers a resume
# when its turn fully completes and a transcript is written, so an automated quit
# that races the turn can legitimately produce no paste. Re-run, or verify claude
# manually, if it flakes.
set -euo pipefail

TAG="codex-resume-paste"
AGENTS="both"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:?}"; shift 2 ;;
    --agent) AGENTS="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SOCK="/tmp/cmux-debug-${TAG}.sock"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG}/Build/Products/Debug"
# App bundle name embeds the tag; resolve it without hardcoding the fork prefix.
APP=$(/bin/ls -d "$DERIVED"/*.app 2>/dev/null | head -1 || true)
CLI="${APP}/Contents/Resources/bin/cmux"

[[ -S "$SOCK" ]] || { echo "FAIL: dev socket not found at $SOCK (is the tagged app running?)" >&2; exit 1; }
[[ -x "$CLI" ]]  || { echo "FAIL: dev CLI not found at $CLI" >&2; exit 1; }

export CMUX_SOCKET_PATH="$SOCK"
# Scrub ambient cmux context so we only ever target the tagged dev socket.
unset CMUX_SOCKET CMUX_SOCKET_PASSWORD CMUX_SURFACE_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_PANEL_ID

cli() { "$CLI" "$@"; }

# read_surface <surface> -> prints recent screen text
read_surface() { cli read-screen --surface "$1" --lines 40 2>/dev/null || true; }

# wait_for <surface> <regex> <max_iters> ; polls read-screen every 2s
wait_for() {
  local surf="$1" pat="$2" max="$3" i=0
  until read_surface "$surf" | grep -qiE "$pat"; do
    i=$((i+1)); [[ $i -ge $max ]] && return 1
    sleep 2
  done
  return 0
}

run_one() {
  local agent="$1" launch quit_regex expect_regex
  case "$agent" in
    codex)
      launch="codex"; expect_regex="(^|/)codex' 'resume'|codex resume '" ;;
    claude)
      launch="claude"; expect_regex="claude' '--resume'|claude --resume '" ;;
    *) echo "unknown agent: $agent" >&2; return 2 ;;
  esac

  echo "── testing $agent ──"
  local surf
  surf=$(cli new-surface --type terminal --focus true 2>&1 | grep -oE 'surface:[0-9]+' | head -1)
  [[ -n "$surf" ]] || { echo "FAIL[$agent]: could not create surface"; return 1; }
  echo "  surface = $surf"

  cli send --surface "$surf" "${launch}\r" >/dev/null
  # Attach detection differs per agent; codex shows "· Ready", claude the Echo box.
  local attach_pat="Context .* · Ready|Welcome|shortcuts|Echo|← for agents"
  if ! wait_for "$surf" "$attach_pat" 30; then
    echo "FAIL[$agent]: agent did not attach"; return 1
  fi
  # Critical: the TUI drops input typed during the splash/attach animation, so
  # settle before sending the prompt, and pause between the text and Enter.
  sleep 4
  echo "  attached; running one turn"
  cli send --surface "$surf" "say ok" >/dev/null; sleep 2
  cli send --surface "$surf" $'\r' >/dev/null
  # Wait for the turn to actually complete (agent prints a response/usage line).
  wait_for "$surf" "Token usage|To continue this session|• ok|esc to interrupt" 25 || true
  sleep 3

  echo "  quitting at prompt"
  # codex quits on double Ctrl-C with a gap; claude wants two RAPID Ctrl-C.
  if [[ "$agent" == "claude" ]]; then
    cli send --surface "$surf" $'\x03\x03' >/dev/null
  else
    cli send --surface "$surf" $'\x03' >/dev/null; sleep 1
    cli send --surface "$surf" $'\x03' >/dev/null
  fi

  # Wait specifically for OUR pre-typed paste (a `cd '<cwd>' && …resume…` line),
  # not the agent's own "run <agent> resume" exit message which appears first.
  # The paste lands shortly after the agent fully exits (PID-exit watch).
  if ! wait_for "$surf" "cd '.*' && '.*(resume|--resume)'" 12; then
    sleep 2
  fi
  local screen; screen=$(read_surface "$surf")
  if grep -qE "$expect_regex" <<<"$screen"; then
    echo "PASS[$agent]: pre-typed resume command detected"
    grep -oE "cd '[^']*' && '[^']*resume[^\"]*" <<<"$screen" | tail -1 | sed 's/^/    /'
    return 0
  fi
  echo "FAIL[$agent]: expected resume command not found. Last screen tail:"
  tail -6 <<<"$screen" | sed 's/^/    /'
  return 1
}

rc=0
case "$AGENTS" in
  both) run_one codex || rc=1; run_one claude || rc=1 ;;
  codex|claude) run_one "$AGENTS" || rc=1 ;;
  *) echo "unknown --agent: $AGENTS" >&2; exit 2 ;;
esac

echo
[[ $rc -eq 0 ]] && echo "ALL PASS" || echo "FAILURES (rc=$rc)"
exit $rc
