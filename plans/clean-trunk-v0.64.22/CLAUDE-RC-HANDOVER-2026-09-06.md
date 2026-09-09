# Claude handover: finish the cmux Mochi RC, then Tim's review

## Assignment and stop condition

Take over the existing release closeout. Finish concrete blockers, verify one
candidate, cut a new signed Nightly and TestFlight build where needed, and give
Tim the actual install locations/build identities plus one final manual checklist.
Do not stop after another narrow green test batch and call the RC ready.

This is NOT permission to add features, extract a shared networking package,
silently waive failures, merge into a shared branch, promote production, or
replace/restart Tim's live app. If the publication lane requires a merge, obtain
Tim's explicit approval first. Tim's final product sign-off remains required.

## Establish the correct checkout before doing anything

- Parent: `/Users/timapple/Documents/mcc/fujira/thefertiliser/cmux-mochi`.
  (Corrected 2026-09-09: the `ventures/mochiexists/mochi-dev` path in the
  original handover was already stale when it was written.)
- Actual repo: `cmux-mochi-clean-v06422` inside that parent, a worktree of
  the `cmux-mochi-clean` checkout beside it.
- Branch at handover: `mochi/transport-hive-foundation` (since merged; work
  now lands on `main`).
- Origin: `git@github-mochiexists:mochiexists/cmux-mochi.git`.
- Pushed implementation/evidence HEAD: `c4bab281804bdf659aeaad8371c4ec3b2529f04e`.
- At handover, no tracked source changes; pre-existing untracked
  `build-universal/` belongs to the user and must not be removed. This new
  handover document is an additional untracked documentation file.
- Do not work in the other `cmux-mochi-clean` baseline worktree or any old
  moved checkout. Recheck `git rev-parse --show-toplevel`, branch, status,
  remote and `git worktree list --porcelain`.

Read `AGENTS.md` / `CLAUDE.md` and the relevant cmux skills. Then read:

1. `plans/clean-trunk-v0.64.22/RELEASE-CLOSEOUT-2026-09-05.md` — active ledger.
2. `plans/clean-trunk-v0.64.22/FEATURE-LEDGER.md` — feature scope, not fresh proof.
3. `plans/clean-trunk-v0.64.22/VALIDATION-MATRIX.md` — historical evidence;
   do not present its old candidate passes as proof for this RC.

The separate Local AI Cat 172-requirement audit is NOT this release's scope.

## Start here: current CI, not yesterday's assumptions

Run: https://github.com/mochiexists/cmux-mochi/actions/runs/33990390707

It is pinned to `c4bab281804bdf659aeaad8371c4ec3b2529f04e`.
Live status checked on 2026-09-06 when preparing this handover:

| Gate | Status | Job ID |
| --- | --- | --- |
| App-host shard 1 | Passed | 101385580569 |
| App-host shard 3 | Passed | 101385580469 |
| App-host shard 2 | Failed — cause not yet inspected | 101385580518 |
| App-host shard 4 | Failed — cause not yet inspected | 101385580520 |
| Release build | Running, not a published release | 101388748452 |
| Aggregate tests | Failed | 101404668952 |

Swift packages, build/lag, Linux preflight, workflow guards, web checks and
remote-daemon tests passed. Refresh the run before acting. Fetch the two failed
job logs and identify actual failures; do not assume they are the same as older
runs. `gh api repos/mochiexists/cmux-mochi/actions/jobs/JOB_ID/logs` can retrieve
a finished job before its overall workflow finishes. Save logs locally and
filter actual assertions/crashes; compiler output can be very large.

The preceding run `33985557097` at `54a2ff23ee` had two distinct problems:

- Shard 4: `stopFollowsMovedPaneToCurrentWorkspace` falsely reported timeout
  despite status 0 and completed `{}` output. The shared test helper is now
  repaired and locally verified. Log: `/tmp/cmux-ci-54a2-shard4.log`.
- Shard 1: its 900-second outer unit-test deadline expired DURING COMPILATION,
  before tests ran, followed by the 300-second idle watchdog. Log:
  `/tmp/cmux-ci-54a2-shard1.log`. Do not blanket-increase assertion timeouts or
  blame a runtime test for a build-phase failure. The newest shard 1 passed.

CI is manual-only: a push does not start it. After a verified fix batch, use
`gh workflow run ci.yml --repo mochiexists/cmux-mochi --ref mochi/transport-hive-foundation`.
Retain exact SHA/run identity and do not report queued or partial jobs as green.

## What the latest batch actually changed and proved

Commits after `54a2ff23ee`:

- `69f2adf4ee`: actual-process regression for delayed completion delivery.
- `78679eb471`: hook/HTML test helpers register termination before launch and
  check child liveness at the unchanged deadline. No production process-runner change.
- `e24acce4ef`: tests independently calculate the intentionally opaque sRGB
  window-background composite; clear local pane fills stay clear.
- `11af90e13a`: generated-template/migration fixtures use Mochi schema URLs.
- `d0fd968229`: explicit-window/topology and typed Codex-error hook mock contracts.
- `b7e0a495c0`: REAL CLI fix — shared simulator/iOS routing resolves the live
  caller pane and rejects a stale caller before dispatch; explicit window/surface
  overrides still win. Reuses the existing English/Japanese localized error.
- `c4bab28180`: closeout evidence ledger.

Executed, not inferred:

- `/tmp/cmux-closeout-schema-theme-completion-red.log`: the new regression
  fails for exited children with status 0 and 7 when notification delivery is
  held; a genuinely live child still times out. The other 24 XCTest cases passed.
- `/tmp/cmux-closeout-schema-theme-completion-green.log`: 24 XCTest + 16
  Swift Testing cases pass, with app/test targets built.
- `/tmp/cmux-closeout-cli-routing-probe.log`: old ambient routing fails the
  missing-pane/stale-surface assertions. Do not mistake that red probe for final state.
- `/tmp/cmux-closeout-cli-routing-green.log`: eight CLI XCTest cases + five
  live-delivery Swift Testing cases pass with the rebuilt bundled CLI.
- `/tmp/cmux-closeout-process-completion-repeat.log`: ten iterations, 70 test
  executions, pass with final helpers and no instrumentation.

Thus 53 focused tests plus 70 repeat executions passed. This is NOT a full-CI,
physical-device, signed-artifact or release-readiness claim.

Earlier important repairs/proof are detailed in the closeout ledger: window
fixture ownership/animation teardown crashes, actual wrong-window divider resize,
Markdown reload expectation over-fulfillment, unsupported-agent restore recipe,
daemon timeout observation and mixed XCTest/Swift Testing watchdog handling.
Existing force-quit/clear-history loops passed on tagged Debug, not on a new
signed RC artifact. All temporary debug probes from those fixes were removed.

## Build and test safely

Root/conductor serializes ALL app-host Xcode runs. Do not have workers contend
for the same GUI test host. Only tagged builds; never replace a live app or use
the default debug socket. Preserve user workspaces and scrollback.

Current isolated verification setup:

- Tag: `ui-test-terminal-cmd-click`.
- DerivedData: `/tmp/cmux-signal-cleanup-dd`.
- Bundle: `com.cmux-mochi.debug.ui.test.terminal.cmd.click`.
- Wrapper: `scripts/ci/run-app-host-xcodebuild.sh`; injects test isolation and
  owns the app-host lock. Retain `TEST_RUNNER_CMUX_TEST_PROCESS` behavior.

Template from the executed runs, adding only the relevant `-only-testing` selectors:

```sh
CMUX_TAG=ui-test-terminal-cmd-click CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
scripts/ci/run-app-host-xcodebuild.sh \
  -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -derivedDataPath /tmp/cmux-signal-cleanup-dd \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.cmux-mochi.debug.ui.test.terminal.cmd.click \
  CMUX_SIDEBAR_EXTENSION_POINT_ID=com.cmux-mochi.debug.ui.test.terminal.cmd.click.cmux.sidebar \
  'INFOPLIST_KEY_CFBundleDisplayName=cmux Mochi DEV Link test' \
  CMUX_SKIP_ZIG_BUILD=1 test
```

Do not use generic `/tmp/cmux-cli` or trust inherited socket variables. For
tagged runtime checks use `CMUX_TAG=... scripts/cmux-debug-cli.sh ...`.
For installed apps re-identify the exact app/CLI/socket first. No caller cmux
workspace was present in this handover session; do not hijack the focused pane.

## Candidate acceptance: finish this before calling it ready for Tim

Freeze one commit and record matching Mac/iOS identities. Refresh evidence after
runtime changes rather than carrying forward an old device pass.

1. Session safety: normal quit AND force-kill/relaunch preserve scrollback,
   prompts, actual workspace folders, agent resume identity and zoom. Include
   Codex working under a repository while touching `~/.codex/memories`, and the
   reported copy-workspace-path/CWD mismatch. Cleared history stays cleared.
2. Pairing: no cmux account/Stack login; fresh QR succeeds; the Mac does not
   flash connected → QR → connected; the phone shows meaningful progress/errors;
   pairing is persisted on BOTH ends before claiming durable success. Verify
   deletion/revocation, not merely hiding a device.
3. Reconnect: phone background/foreground and cold launch, Mac restart, lost
   network and recovery; no repeated chat bounce or endless reconnect/pair loop.
   Technical reconnect status must match actual operations. Check useful
   Tailscale guidance when the required remote path is unavailable.
4. Network routes: observe same-Wi-Fi LAN, phone hotspot including USB tether,
   and Tailscale-only paths; switch between them. Do not infer the route from a
   UI label or assume hotspot implies LAN reachability. Record fallback behavior.
5. Sidebar/files: Finder wording, workspace drag highlight/spring-load, empty
   group immediately accepts drops, Shift-selected multi-tab moves to existing
   and new drop zones, local and wrapped Cmd-click paths open as files, not
   `https://documents/...`.
6. Reliability/parity: transient test servers disappear from the port list;
   descriptor counts remain bounded under export/restore/network churn. Verify
   the complete required feature ledger, including adaptive pane placement,
   zoom persistence, opaque update popover, CLI submit/wait, fork Sentry policy,
   Privacy Frost/redaction, resource footer/Task Manager, artifacts, reopen-closed,
   safe resume aliases, bundled skills and no unpurchasable Pro prompts.

Use the repo's iOS reload/E2E scripts with SAME-TAG Mac, isolated simulator, and
physical phone. Previously used iPhone ID:
`632BE7C8-A445-5F1B-8EE1-F352CB50ABBD` (re-enumerate, do not assume online).
Current network, unlocked state and pairing state must be rechecked.
No Stack credentials are needed for this account-free QR acceptance flow.

## Nightly and TestFlight: conditional publication, not simulated success

Tim requests fresh RC review builds where needed. Compare the candidate to the
last actually published Nightly and the last successfully UPLOADED/available
TestFlight build; overall workflow success is insufficient.

- A Nightly must contain all unshipped desktop fixes, including the descriptor,
  restore, routing and accepted parity work. Do not offer an older release just
  because Sparkle shows an update.
- Cut TestFlight if mobile/shared changes needed for this candidate are not
  already distributed. If reusing an existing iOS beta, prove its exact identity
  and compatibility with this Mac candidate; do not claim a new build was cut.
- Read the FORK workflows `.github/workflows/nightly.yml`,
  `.github/workflows/ios-testflight.yml`, and release/overlay guards. Do not copy
  upstream `manaflow-ai/cmux` publishing commands from a generic skill.
- Existing lanes publish Nightly / upload TestFlight only from `main`.
  A branch dispatch can build or skip without publishing. If this still requires
  landing the branch, ask Tim explicitly before the shared-branch merge; do not
  bypass that gate or treat this handover as merge authorization.
- Use fork signing/team/bundle IDs and monotonic build numbers. Verify signing,
  notarization/update feed and downloadable artifacts. Verify TestFlight upload,
  processing and tester-group availability separately.
- Download and smoke-test the actual distributed artifacts after publication;
  a local Debug build does not prove the installer/beta works.
- Do not auto-install/restart Tim's main session. Obtain a fresh verified backup
  before an authorized live replacement. A historical backup exists at
  `/Users/timapple/Documents/cmux-before-restart-20260905-1a9D2g`, but it is NOT
  a backup of today's edits. Its 1.8 GB included workstream/history, not just
  current workspace state. Do not delete recovery data to shrink it.
- Historical warning: stable `v0.64.207` did not contain Ghostty descriptor fix
  `fd9b5b94b11c99fd5105759e1145f8fde6dac72c`; current source and the previously
  inspected Nightly did. Recheck current artifacts rather than assuming this
  historical statement still identifies the latest installed build.

## Markdown editor conclusion — resolved, no new feature required

The desktop fork ALREADY has in-pane Markdown source editing. In the Markdown
pane, the document/plain-text toolbar button is labelled **Show TextEdit**;
it switches to the built-in editor, not Apple's external TextEdit application.
Edit, Save/Revert, and switch back with **Show Preview**. This is not WYSIWYG.

Implementation: `Sources/Panels/MarkdownPanelView.swift` and
`Sources/Panels/MarkdownPanel.swift` (`saveTextContent`). It was also present
in previously inspected installed Nightly source revision `9469a89`.
All 30 Markdown tests passed in the prior tagged closeout run, including the
corrected reload expectation. Verify the mode/save flow on the eventual artifact.
Do not expand this RC into building a new editor. Richer editing and mobile
Markdown/artifact discoverability remain discussion/backlog items.

## Final handoff to Tim

Return ONE concise review package:

- Candidate commit; Mac version/build/channel and install link; iOS version/build
  and actual TestFlight availability (or the verified reused-beta decision).
- What you executed: full CI, isolated runtime, real phone, network routes and
  distributed-artifact checks, each tied to candidate identity.
- The manual checklist above with concrete expected outcomes and a compact full
  required-feature list from the refreshed ledger/welcome catalogue.
- Any remaining blocker or explicit exclusion. No green-by-omission reporting.
- Ask for Tim's final RC sign-off. Production promotion follows only explicit
  approval; do not automatically publish or install production.

Keep work finite. Only failing agreed acceptance criteria reopen implementation.
Shared-package extraction, new networking features and inline VS Code/Claude
browser integration are out (the latter was explicitly retired).
