# Release 0.64.201 handoff — state, findings, fix designs, pending work

Date: 2026-08-09. Branch: `mochi/on-v0.64.20-wip` @ `407284793d`.
Audience: the agent (Codex) and Phil, picking up the release push from the
2026-08-09 verification session.

## 1. Where the release stands

- **Trunk**: `mochi/on-v0.64.20-wip` is the single live line. It contains the
  complete v0.64.173 fork replay on upstream v0.64.20 (see `PARITY-REPORT.md`),
  the DeviceLink/account-free-pairing work, and the merged per-route
  reachability probe (`76d7df4ba8`, 13/13 tests green). Version staged:
  **0.64.201 (build 119)**. Everything is pushed.
- **Signed release candidate exists**: nightly run 31293379692 built, signed,
  and notarized `76d7df4ba8`. Installed side-by-side at
  `/Applications/cmux Mochi NIGHTLY.app` (`com.cmux-mochi.nightly`,
  0.64.201-nightly). Identity verified: Developer ID Atlas Codes LTD
  (599WAZ6282), Gatekeeper accepted, DMG stapled (app bundle itself is not
  stapled — lane quirk, acceptable), Sparkle feed = Mochi nightly appcast, no
  upstream leakage. Branch nightlies publish as **run artifacts**
  (`cmux-nightly-<sha>`), not the public nightly release feed.
- **Automated parity proof passed** on both the tagged debug build and the
  signed nightly (harness scripts + evidence in the session scratchpad
  `/private/tmp/claude-501/-Users-timapple-Documents-mochi-mochi-dev/bcd636bf-8205-4c82-b04c-8d2768c2159e/scratchpad/`):
  placement matrix (bug-for-bug stable parity), quit→relaunch restore
  (topology/scrollback/cwd), agent resume Off/Medium/Full with a real Claude
  session (incl. no-duplicate-provider and no unsafe-flag escalation),
  conductor guard + `--force`, workspace capture, Welcome catalog, mobile
  status RPC.

## 2. Finding: password socket mode locks out cmux's own shell integration

**Symptom found on the nightly**: `cmux send` into a pane with a live
foreground job (`sleep 999`) was accepted; the Debug build of the same commit
refused with `live_foreground_job`.

**Root cause (verified end-to-end)**: `com.cmux-mochi.nightly` had
`socketControlMode = password` persisted from an earlier nightly install. In
password mode, `authResponseIfNeeded`
(`Sources/TerminalController+SocketClientCapability.swift:135`) short-circuits
**every** non-`auth` command on an unauthenticated connection. The shell
integration hooks (`_cmux_send` → raw `nc` line) never authenticate, and the
app does not put `CMUX_SOCKET_PASSWORD` in pane environments — so all
`report_shell_state` / `report_pwd` / `report_tty` / `ports_kick` telemetry is
rejected. Consequences: `PanelShellActivityState` never reaches
`commandRunning` → `ControlSurfaceSendGuard` fails open; sidebar pwd/git/ports
reporting silently dies. Flipping the nightly to `cmuxOnly` and relaunching
restores the guard (verified live). Not a Debug/Release code difference; pure
configuration. Stable v0.64.173 almost certainly has the same behavior in
password mode.

### Recommended fix design

The codebase already has the right primitive: the **socket client capability**.
Panes spawned by cmux receive `CMUX_SOCKET_CAPABILITY` (HMAC token issued by
`SocketClientCapabilityAuthority`, wired via
`TerminalSurfaceRuntimeWiring.swift:46`), and the wire protocol supports
wrapping any command as `_cmux_capability_v1 <token> <command>`
(`SocketClientCapabilityEnvelope.wrap`). Today the envelope is only honored in
`cmuxOnly` mode (`SocketClientAuthorization.authorizedCommand`).

Two coherent halves:

1. **Server** — in `authResponseIfNeeded` (password mode), before returning
   `auth_required`: if the command carries a capability envelope that
   `capabilityAuthority.verifies(...)`, accept it. Scope the bypass to the
   telemetry namespace (`report_*`, `ports_kick`) so password mode keeps its
   control-plane guarantee; a capability-bearing telemetry line can only
   update UI state, so spoof impact is bounded. (Accepting the full command
   set under a verified capability is defensible too — the capability is only
   exported into cmux-created terminals — but telemetry-only is the
   conservative first step.)
2. **Shell integration** — teach `_cmux_send` (in the app's
   `Resources/shell-integration` scripts) to wrap payloads when the env var is
   present:
   `print -r -- "_cmux_capability_v1 $CMUX_SOCKET_CAPABILITY $payload" | nc …`.
   Verify first that `CMUX_SOCKET_CAPABILITY` actually reaches pane shells in
   Release (it is wired app-side; confirm in a pane with
   `echo ${CMUX_SOCKET_CAPABILITY:+SET}`).

Tests (red/green per repo policy): package tests in
`CmuxControlSocketTests/SocketClientAuthorizationTests` for password+envelope
(verified/garbage/missing × telemetry/control commands), plus a
shell-integration-level test that a pane's `report_shell_state` lands while
`socketControlMode = password`. The live repro is trivial:
`defaults write com.cmux-mochi.debug.<tag> socketControlMode password`,
relaunch, run `sleep 999` in a pane, `cmux send` into it — must be refused
after the fix.

## 3. CI — fixed today, and what may remain

Fixed and pushed (commits `8834f17d3a`, `6bd6b364e1`, `046fd39417`,
`407284793d`):

- Deleted upstream's standalone `ui-regressions` job from ci.yml (the fork
  runs display regressions inside `tests-build-and-lag`; the stray job ran on
  a hosted runner with no second display and failed; the topology guard
  correctly flagged the duplicate).
- Re-stamped stale guards to the fork overlay's deliberate shape:
  runner guard (no `ui-regressions`), attestation-retry guard (retries are
  `continue-on-error` in both lanes since `409930e7c5`), R2 guard **inverted**
  (fork workflows must never reference `scripts/ci/upload-r2-object.py`; the
  uploader's own dry-run checks stay).
- Wired `DeviceLinkKit` into `cmux.xcworkspace` package groups (missed since
  Aug 2; `check-workspace-package-groups --check` would fail).
- Refreshed `.github/test-determinism-allowlist.txt` (+DeviceLink reconnect
  UI-test sleep; −2 entries whose suite is already determinized).

All 49 `workflow-guard-tests` steps were run locally; only two local-env
artifacts remain (bash-3.2 PTY test, git-ignored `build/` dir) that do not
affect Linux CI. **A CI run on `407284793d` was dispatched ~13:45 local — check
its outcome first.** Known possible stragglers:

- `web-typecheck`: bun "Fail extracting tarball for next" — infra flake,
  re-dispatch clears it.
- The display-churn test now runs inside `tests-build-and-lag` on
  `vars.MACOS_RUNNER_DISPLAY` = `macos-15` (GitHub-hosted). If it fails there
  the same way the standalone job did, the variable needs to point at
  self-hosted display hardware (see repo CLAUDE.md runner table).
- `test-ios.yml` / `package-conventions-lint`: ~8 pre-existing convention
  violations in the Aug 2–4 DeviceLink code (singleton `MobileDeviceLinkClient`,
  `NSLock`, namespace enums, free function, `CmxIrohTCPFirstActivation`,
  `DeviceLabel`, `EndpointResolution`). Decide refactor vs sanctioned
  `lint:allow` justifications; this also unblocks the cancelled simulator jobs.
  Do not silently refactor phone-tested DeviceLink code close to the release.

Dispatch notes: workflows are dispatch-only; `gh` must be on the
**mochiexists** account (`gh auth switch --user mochiexists`) or dispatches
403; always pass `-R mochiexists/cmux-mochi`.

## 4. Other open findings

- **Full-resume boot flake (one occurrence)**: on one full-mode restore,
  claude drew its banner then exited to the shell; an immediate scripted repro
  restored correctly (live TUI, same session ctx, safe flags). Keep an eye out
  during dogfood; if it recurs, capture `~/Library/Logs` + the pane scrollback
  before closing it.
- **Adaptive placement third-pane defect** (Markdown/Artifact second add
  creates a third pane instead of reusing the right pane): bug-for-bug parity
  with stable v0.64.173 — ship as-is; improvement tracked by
  `placement.adaptive-right` in `plans/fork-overlay-cleanup/FEATURE-LEDGER.md`.
- **App-bundle stapling**: nightly DMG is stapled, the .app inside is not.
  Harmless online; worth aligning with the stable lane before the public cut.

## 5. Phil's manual dogfood list (automation cannot reach these)

On `/Applications/cmux Mochi NIGHTLY.app` (already installed):

1. Privacy Frost: right-click workspace → Blur; check sidebar row redaction
   (the Aug 8 whole-row fix) and a workspace capture's redaction. No CLI route
   exists and sidebar captures render vibrancy-empty, so this is eyes-only.
2. Sidebar spring-load drag feel.
3. Updater pill/popover look + a real Sparkle check against the nightly feed.
4. Phones: account-free QR pairing, DeviceLink unpair/re-pair + reconnect,
   the open iPhone-17 machine-filter bug (16 works, 17 shows none), and
   Settings → Mobile per-route reachability verdicts with Tailscale up.
5. General look/feel → go/no-go.

## 6. Release train after go

1. CI green (or accepted-red with rationale) on the trunk head.
2. Archive-tag old `main` (e.g. `archive/pre-v06420-main-<date>`), then reset
   `main` to the trunk head and force-push. Do **not** `git merge` across the
   rebase — the lineages diverged via semantic replay. Re-point the
   `cmux-mochi-clean` checkout afterwards.
3. Cut **0.64.201** via the release lane (version/build already staged;
   per policy no further version bumps without Phil's say). Run
   `scripts/release-pretag-guard.sh` first, and walk the 6-point release-path
   checklist (runners, bonsplit remote, timeouts, app name, channel verifier,
   R2 guard) — the guards re-stamped today cover part of it, not all.
4. Parked for after the release: `feat/native-codex-resume-paste` (needs the
   codex-fork ThreadUnsubscribe event), `fix/codex-lifecycle-push` (WIP),
   password-mode capability fix (§2) unless it makes this train.

## 7. Repo/folder state (for orientation)

`~/Documents/mochi/mochi-dev/` now holds exactly two cmux checkouts:
`cmux-mochi-clean` (repo host, parked on the historical
`release/0.64.173-baseline`, clean) and `cmux-mochi-v06420` (the trunk
worktree). All old worktrees are removed; every branch, including previously
local-only ones (`route-reachability-probe`, `native-codex-resume-paste`,
`codex-lifecycle-push`, `agent-surface-attach-placement`, `artifacts`), is
pushed to origin. The evidence-grade session detail lives in the proof-harness
scripts and `evidence-*/` directories in the scratchpad path in §1.
