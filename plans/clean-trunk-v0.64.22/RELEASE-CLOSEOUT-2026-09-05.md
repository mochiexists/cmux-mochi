# Mochi release closeout — active, not release-ready

This is the finite closeout checklist agreed with Tim on 2026-09-05. The older
`VALIDATION-MATRIX.md` contains historical evidence for `1cb18b3866`; its green
rows are not final-candidate sign-off. The Cat ecosystem's separate 172-item
report is not this release's scope.

Working checkout: `cmux-mochi-clean-v06422`, branch
`mochi/transport-hive-foundation`. Candidate is not frozen yet. Installed stable
and Nightly apps have not been replaced by this closeout pass.

## Stop rule

Only failures of the agreed acceptance criteria reopen implementation. Shared
package extraction, additional networking improvements, and the agreed mobile
Markdown/Artifact viewer discoverability backlog are excluded. Production
promotion requires Tim's manual sign-off; never auto-install into his main session.

## Remaining gates

1. Resolve/classify concrete automated failures, with executed evidence, not
   unexplained red tests or blanket timeout increases.
2. Freeze matching Mac/iOS source and build identities, and refresh the feature
   ledger against that candidate.
3. Run candidate acceptance: session safety; simulator and physical iPhone QR,
   persistence, reconnect and observed Wi-Fi/hotspot/Tailscale route changes;
   sidebar multi-drag/highlighting/new groups; Finder wording; local-file links;
   stale ports and bounded descriptor growth; existing fork parity selectors.
4. Produce signed Nightly/TestFlight artifacts, verify their source/build
   identities, smoke-test the distributed artifacts, and provide one manual list.
5. After Tim's sign-off, promote production and verify downloads/update feed.

## Current executed evidence

| Check | Result and scope |
| --- | --- |
| Terminal Cmd-click | 25 native UI tests passed; 264 terminal-core tests passed. Includes the reported wrapped HTML path and actual Ghostty callback. |
| CLI SSH session-attach anchor | Four tests failed on CI because mock authentication was parsed as JSON. Fixture corrected in `0e6c3f2c5b`; all four passed locally. No production authentication change. |
| Force-quit continuity | Isolated tag `ui-test-terminal-cmd-click` passed two SIGKILL/relaunch marker/prompt restores, followed by clear-history and a third SIGKILL/relaunch. Cleared history stayed cleared. Build used production source from `6d46ff5f97` plus test-only anchor correction. |
| Refreshed force-quit continuity | `/tmp/cmux-closeout-force-quit-final.log` passed the same complete loop using the app rebuilt for the consolidated run, including production fix `8bc4405fab`. Test-only source at build time was `ebc40f2cc0` plus the subsequently committed `377fb04c15` window fixture. This is tagged Debug evidence, not signed Nightly evidence. |
| Focused desktop acceptance | 124 Swift Testing cases in seven suites plus seven XCTest cases passed: resume metadata, pane zoom, groups, drag/drop planners, selection anchors, and port TTY freshness. This does not replace human pointer or device proof. |
| File-preview lifetime fixtures | Both CI crash cases reproduced locally. Corrected ARC window ownership and production text-view construction; the full 27-case XCTest class passed without those crashes. |
| Unsupported custom-agent resume | Two failing hibernation tests now pass after the shared startup-input builder preserves the unsupported-agent/no-recipe result. The full hibernation, termination, and auto-resume suites completed successfully in the focused run. |
| Observer and clipboard fixtures | Full observation and artifact-store suites passed with positive rollout/CWD assertions and bounded asynchronous lease-removal assertions. |
| Daemon timeout test | Test-only asynchronous callback wait retains the one-second deadline; deliberate missing-event fault injection fails; the full 25-test package passes locally. CI confirmation remains required. |
| Daemon timeout repair after CI probe | Owned callback queue and actual receipt-time assertion replace global-queue scheduling sensitivity. All 25 package tests pass locally (including two observation variants); ten focused repeats pass both variants. With the event deliberately withheld, both variants fail. Logs: `/tmp/cmux-timeout-repair-ci-probe.log`, `/tmp/cmux-timeout-repair-final-green.log`, `/tmp/cmux-timeout-repair-missing-event-red.log`. |
| Consolidated corrected cases | `/tmp/cmux-closeout-final-targeted.log`: 126 Swift Testing cases in ten suites passed; 58 of 59 XCTest cases passed. The sole failure is the development-source SSH upload fixture described below. The overall command correctly exits 65, not success. |
| WebKit capture and restore | The zoomed capture needs a foreground, unoccluded test window: activation changed its occlusion state and capture completed in 1.571 seconds. No production screenshot change. Download restore passed in 0.444 seconds with local HTML and an asynchronous readiness wait. |
| Preview and Markdown | The consolidated run passed all 27 file-preview and 30 Markdown tests without the reported lifetime crashes. |

Local logs: `/tmp/cmux-closeout-ssh-anchor-green.log`,
`/tmp/cmux-closeout-force-quit-20260905.log`,
`/tmp/cmux-closeout-acceptance-selectors.log`.

## Concrete blockers under investigation

### Latest CI refresh: `33965443888` at `d7911a442a`

The daemon timeout repair is now confirmed on CI: all 25 package tests pass,
including both delayed-observation variants. The overall run remains **failed**.
Build/lag and app-host shards 2 and 3 passed; Foundation and shards 1 and 4 failed.

- Foundation's queued-input PTY test failed to observe either backoff or input.
  A fresh local full-package run passed all 175 tests, and 20 isolated queued-input
  repeats passed. A subsequent full-package repeat failed a different signal-exit
  timing assertion. Neither failure is classified as fixed. Failure-only PTY
  transcript/attach-log diagnostics were added; no retry deadline or production
  reconnect logic was changed.
- Shard 1 recorded 60 distinct failing XCTest methods across 14 classes; shard 4
  recorded 65 across 20 classes. These are not 125 proven production regressions,
  but neither are they waived. Evidence clusters include stale upstream identity,
  schema and compositing expectations; outdated CLI mock surface responses; and
  process completion observers reporting timeout despite successful child output.
- Three shard-4 SIGSEGV selectors remain explicit blockers:
  `TerminalNotificationSocketActionTests.testNotificationJumpToUnreadPayloadMatchesOpenedFallbackNotification`,
  `TerminalWindowPortalLifecycleTests.testDockDividerLifecycleScopesTerminalResizeToHostingWindow`,
  and `BrowserPortalFirstRevealScrollTests.nextTurnRestoreSurvivesDetachment`.
  CI backtraces are unsymbolicated; no xcresult artifact was uploaded. Logs are
  `/tmp/cmux-ci-d791-shard1.log` and `/tmp/cmux-ci-d791-shard4.log`.
- A separate watchdog defect is reproduced: XCTest's `Selected tests` summary
  starts the 45-second post-test timer even though Swift Testing starts afterward.
  A synthetic mixed-framework child was incorrectly killed with exit 0 before its
  Swift test finished. The repair tracks both frameworks and preserves failures;
  it does not explain or waive the earlier assertions/crashes.
- The unsafe-selector restore test used custom agents without a resume recipe,
  contradicting the intended unsupported-agent result. Its corrected fixture
  checks both no-recipe rejection and the safe selector with a real resume recipe.
- Focused local reproduction (`/tmp/cmux-closeout-d791-crash-selectors.log`):
  all three corrected restore tests passed, as did the notification and browser
  detachment selectors. The dock-divider selector failed its window-scoped resize
  assertion, not a crash. The Markdown reload test aborted in
  `XCTestExpectation.fulfill`; its subscriber allowed repeated matching file-change
  publications to fulfill one expectation repeatedly. The fixture now takes only
  the first matching publication, retaining the timeout and final content checks.
  The combined run exited 65 and is not a pass or clearance of the CI SIGSEGVs.
- Mixed-framework watchdog validation: 14 subprocess scenarios pass, including
  XCTest-pass/Swift-fail returning 125 and an unfinished silent Swift run returning
  124. The existing shell retry test also passes. Regression commit `aaf36b75b7`,
  fix `65c3395991`; a fresh actual CI run remains required.
- Follow-up tagged app-host run
  `/tmp/cmux-closeout-markdown-restore-green.log` **TEST SUCCEEDED**:
  all 30 Markdown XCTest cases and all three restore-startup Swift Testing cases
  pass after the fixture fixes. The app and test target compiled successfully.
  These narrow passes do not clear the separate dock-resize assertion or CI-only
  crashes. The queued-input diagnostics-only change compiled and its focused
  test passed (`/tmp/cmux-queued-input-diagnostics-check.log`).

No new Nightly/TestFlight has been cut. Complete the concrete failure clusters
and candidate/device gates above before claiming release readiness.

### Window ownership and resize follow-up

- Original CI reports were recovered from the configured M4 runner:
  `/tmp/cmux-ci-d791-notification-crash.ips`,
  `/tmp/cmux-ci-d791-dock-crash.ips`, and
  `/tmp/cmux-ci-d791-browser-crash.ips`. All three identify
  `objc_release -> _NSWindowTransformAnimation dealloc -> autorelease pool ->
  CA transaction commit`. The dock case pumps the run loop in
  `realizeWindowLayout`; that selector is not proof the dock created the bad window.
- Full notification + first-reveal suites reproduced three bad-pointer crashes
  locally in `/tmp/cmux-closeout-window-churn-red.log`, including browser
  detachment. Their shared fixtures closed strongly held windows with default
  close ownership and pending animations. The fixture correction sets
  `isReleasedWhenClosed = false` and `animationBehavior = .none` before presentation,
  retaining existing close/order-out cleanup. Production animation is unchanged.
- A separate dock probe (`/tmp/cmux-closeout-dock-probe.log`) established the
  resize-routing bug: expected/hosted window 9575, stale event window 9567;
  controller drag active, resize ownership active only for 9567. Dock, workspace,
  and remote-mirror divider entrypoints now prefer their attached/visible hosting
  window, falling back to the event window only when no host is available.
  This is a runtime change and requires refreshed candidate dogfood.
- Stable/Nightly auth and build-flavor fixtures now use the fork's bundle IDs,
  retaining dev precedence and separate stable/Nightly callback assertions.
- The SSH creation mock now returns the initial `surface_id`, matching the real
  server contract. Standalone bundled-CLI proof: old fixture exits 1 after
  `surface.list`/rollback; corrected fixture exits 0 through create, rename,
  configure, select, with the original payload assertions retained.
- The adjacent final-size test initially failed intermittently (two of five
  repeats). Instrumented repetitions showed a pending update settling without
  another resize request in 5–7 ms, and occasional measurement before initial
  terminal readiness. The fixture now waits for initial readiness using the
  existing bounded helper, then observes final width within 0.5 seconds instead
  of assuming exactly two queue hops. No resize engine change was made for this
  observation issue. All temporary probes are removed.
- `/tmp/cmux-closeout-window-resize-final.log` **TEST SUCCEEDED**: 15 XCTest
  cases plus 40 Swift Testing cases passed. This includes the complete notification
  and browser first-reveal suites, all three selected resize cases, fork identity
  coverage, and the native bundled-CLI SSH creation test. The same tagged app and
  test targets compiled successfully. The full CI run and candidate dogfood are
  still required; other previously identified failure clusters remain open.
- Final-size verification then passed 20 consecutive iterations with the final,
  probe-free fixture (`/tmp/cmux-closeout-resize-flush-final-repeat.log`).

- CI run `33951214221`, source `6d46ff5f97`: Swift package timeout-isolation
  callback wait failed; SSH anchor fixture failed; app-host shard 1 had five
  Swift Testing issues and XCTest post-test crashes. Shard 2 also failed with
  screenshot-count and download-restore assertions. Release build was skipped.
- The daemon timeout case failed again on CI `33962543128`; the nonblocking
  wait alone did not fix it. Instrumented CI `33964233854` at `45a6e6acd5`
  reproduced the cause: the dedicated queue ran at 0.146 seconds, but the
  global-queue PTY events and global sentinel ran at 2.233 seconds, after the
  one-second deadline. The observer task itself resumed at 2.228 seconds.
  This establishes test callback-queue starvation, not missing transport data.
  The fixture now uses its own delivery queue (like the actual PTY bridge),
  records callback receipt time, and checks that timestamp against the unchanged
  deadline. Immediate and deliberately delayed observation are both exercised.
  No production transport code changed. The temporary timing probes were removed.
  Missing-event fault injection fails both variants, as required. Fresh CI must
  still confirm the corrected fixture on macOS 15.
- The corrected zoom, artifact-count, lease, observer, download-restore and window
  fixtures pass locally. The broader screenshot suite was stopped after a
  separate navigation fixture hung; it has not been claimed as a full-suite pass.
- The SSH upload fixture still exceeds its two-second expectation locally. An
  earlier sample showed dev-only source fingerprinting blocked in directory
  `open` for about 97 seconds, before upload; the consolidated case took 55.766
  seconds. TCC is a hypothesis, not an established cause. The separate Zsh
  history case passed in 0.067 seconds in the consolidated run.
  The fake upload was recorded at 55.754 seconds and its path/stdin assertions
  passed; the sole failure was the elapsed expectation. Normal shell hashing
  took 0.07 seconds. Classification: unisolated app-host filesystem dependency,
  not demonstrated SSH upload regression. No deadline was increased or test
  disabled. Isolating it requires a fingerprint-provider seam; that is not
  silently added as a runtime change during this closeout. CI must confirm the
  corrected candidate; the local run remains red.

## Continued failure remediation after `54a2ff23ee`

- CI `33985557097` at `54a2ff23ee` passed Swift package tests and the
  build/lag check. App-host shard 4 failed its prerequisite hook gate:
  `ClaudeHookLiveDeliveryTargetTests.stopFollowsMovedPaneToCurrentWorkspace`
  reported `timedOut: true` despite status 0 and completed `{}` output.
  Its log is `/tmp/cmux-ci-54a2-shard4.log`. The job stopped before the full
  shard, so this does not clear the older full-shard failures.
- The shared hook harness and HTML-open helper waited on a global-queue exit
  observer. A delayed observer could classify an already-exited child as a
  timeout. The new actual-process regression holds observer delivery and checks
  both exit 0 and exit 7; a live sleeping child remains a negative control.
  Native app-host red proof recorded both expected failures in
  `/tmp/cmux-closeout-schema-theme-completion-red.log`; regression commit
  `69f2adf4ee` precedes repair `78679eb471`. These are local red/green results,
  not a claim that CI has run those new commits.
- The repair registers completion before launch and checks actual process
  liveness at the unchanged deadline. No production process runner changed.
- Background tests now independently calculate the opaque sRGB composite
  introduced intentionally by `379033c4bf`, preserving clear local pane fills.
  Generated-template and legacy-migration schema fixtures now use the fork's
  intended URLs. No runtime color or settings behavior changed.
- `/tmp/cmux-closeout-schema-theme-completion-green.log` **TEST SUCCEEDED**:
  24 XCTest cases and 16 Swift Testing cases in four suites passed, including
  the process regression, hook lifecycle/PID authentication and HTML-open tests.
  The tagged app and test target built successfully.
- Native CLI probe `/tmp/cmux-closeout-cli-routing-probe.log` distinguished
  incomplete explicit-window/mock-hook responses from a real simulator routing
  gap: ambient commands omitted the caller's pane and dispatched even when the
  caller surface was stale. Both existing regression selectors failed before
  the runtime correction. This inconsistency already exists in upstream
  introduction `aac235180e`; it is not evidence of a deliberate fork change.
- Shared simulator/iOS routing now resolves the live caller pane from
  `surface.list` and rejects a stale caller before dispatch. Explicit window or
  surface targeting still overrides ambient context. The existing
  `cli.simulator.error.callerSurfaceUnavailable` message is reused; its English
  and Japanese catalogue entries were parsed and verified, with no new strings.
- CLI mock fixtures now answer the actual window/topology and hook protocol.
  The typed Codex error assertion retains the exact error body and target IDs
  while checking the intentionally asynchronous notification command.
- `/tmp/cmux-closeout-cli-routing-green.log` **TEST SUCCEEDED**: eight XCTest
  cases and all five live-delivery Swift Testing cases passed. Coverage includes
  ambient/stale simulator routing, explicit-window precedence, numeric simulator
  and iOS selectors, screenshot preparation and typed Codex error notification.
  App/test targets and the bundled CLI rebuilt successfully. This does not prove
  physical-device networking or clear the remaining full-CI failures.
- `/tmp/cmux-closeout-process-completion-repeat.log` **TEST EXECUTE SUCCEEDED**:
  ten iterations of the completion-regression and live-delivery suites passed
  (70 test executions), using the final built helpers without instrumentation.
- The existing desktop Markdown pane already has built-in source editing,
  Save/Revert and preview switching. Its toolbar calls the editing toggle
  **Show TextEdit**; this is not a WYSIWYG editor. No new Markdown feature was
  added to this release closeout.

## Publication boundary

The current fork workflows publish Nightly and upload TestFlight only from
`main`. A working-branch Nightly dispatch builds but does not publish, and a
working-branch TestFlight dispatch does not upload. Publishing this candidate
therefore also requires the explicit dogfood/merge approval required by
`AGENTS.md`; do not silently merge or bypass these guards to report a release.

No Nightly, TestFlight, or production publication has been performed for this
candidate. Final device/network-route acceptance remains open.
