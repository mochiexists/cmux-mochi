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

## Publication boundary

The current fork workflows publish Nightly and upload TestFlight only from
`main`. A working-branch Nightly dispatch builds but does not publish, and a
working-branch TestFlight dispatch does not upload. Publishing this candidate
therefore also requires the explicit dogfood/merge approval required by
`AGENTS.md`; do not silently merge or bypass these guards to report a release.

No Nightly, TestFlight, or production publication has been performed for this
candidate. Final device/network-route acceptance remains open.
