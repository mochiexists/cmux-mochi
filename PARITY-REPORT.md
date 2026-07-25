# cmux Mochi v0.64.20 parity report

Date: 2026-07-25

## Result

The Mochi fork overlay has been replayed onto upstream `v0.64.20`, audited
against the pre-rebase `v0.64.173` release, and corrected for the parity gaps
found during review.

Source parity and automated validation are complete. This branch has not been
pushed, signed, notarized, installed, launched, or released, so live dogfood
and release-pipeline proof remain separate readiness steps.

| Role | Ref | Commit |
| --- | --- | --- |
| Previous upstream base | `v0.64.19` | `1c22c55643` |
| New upstream base | `v0.64.20` | `14e3400b95` |
| Pre-rebase parity oracle | `v0.64.173` | `6cc68ba8cc` |
| Source fork stack | `mochi/on-v0.64.19` | `966ef01b6f` |
| Prepared branch | `mochi/on-v0.64.20-wip` | local only |
| Validated implementation head | | `843afd178e` |

## Uplift size

- 232 upstream commits between `v0.64.19` and `v0.64.20`.
- 2,254 files changed by upstream.
- 40 source-stack commits touching 292 files.
- 95 files changed by both upstream and the fork.
- 38 applicable source commits replayed.
- 2 obsolete inputs omitted: the old version bump/revert pair and old
  GhosttyKit checksum pin.

This was a medium-to-large semantic replay, not a tag-only update.

## Parity corrections

### File-backed tab actions

The Welcome catalog claimed file actions, but the first replay did not expose
them. The v0.64.20 branch now restores:

- Reveal in Finder.
- Copy File, which writes a pasteable file URL object plus a string-path
  fallback to the macOS pasteboard.
- Copy Path.
- File-header actions and Bonsplit tab context-menu actions for Markdown, file
  preview, artifact, and local file-backed browser tabs.

The host-provided Bonsplit context-menu API is committed in the submodule at
`033ba4cb8e0c3373d82edc0a82e2d5b3cc7ce959`.

### Task Manager convergence

The pre-rebase release's complete Task Manager experience is restored:

- Always-on CPU and memory quick glance in the sidebar footer.
- Task Manager opens as a normal reusable tab.
- The tab uses the full available area and includes process detail.
- The sidebar Task Manager selection remains ephemeral and persists as the
  normal tabs selection.
- Task Manager tabs are intentionally excluded from saved layouts and session
  restoration.
- v0.64.20 canvas, stable-surface identity, panel-binding, and exhaustive
  `SurfaceKind` requirements are handled.

### Restored agent working directory

An isolated rerun exposed a real replay regression: 16 agent-resume tests
accepted a spurious home-directory report after restore. The v0.64.20
adaptation had retained a baseline condition that disabled the restored-cwd
guard whenever Ghostty started directly in the saved directory.

The guard is now retained as defense in depth on both direct-cwd and guarded
startup-command paths, matching the pre-rebase invariant. The complete
`AgentSessionAutoResumeSwiftTests` suite now passes independently.

### Other v0.64.20 adaptations

- Privacy Frost uses v0.64.20's immutable sidebar snapshot model.
- Agent resume retains v0.64.20 session-width/alignment behavior and Mochi's
  Off/Medium/Full settings.
- Workspace screenshot support retains v0.64.20 browser design mode.
- Welcome and project-source catalogs include both upstream and Mochi entries.
- Mobile host identity is channel-aware while retaining `com.cmux-mochi`.
- The duplicate fork `v2AwaitCallback` was removed in favor of the v0.64.20
  helper.
- Browser read-screen handles the new `.timedOut` result.
- Bonsplit's new `.disconnectRemote` action is routed through the workspace's
  remote-disconnect path.
- `.github/swift-file-length-budget.tsv` remains deleted because v0.64.20
  removed the complete budget system.
- Ghostty is pinned at `bb30526cdab8f5fb08ae43e404e3aacc40d3ffc3`
  with the matching cached GhosttyKit.

## Validation

| Gate | Result |
| --- | --- |
| Focused Welcome, file-tab, and Task Manager tests | Pass |
| Agent resume plus new Task Manager parity tests | 29 passed, 0 failed |
| `CmuxWorkspaces` package | 154 tests in 22 suites passed |
| Bonsplit package | 201 XCTest plus 2 Swift Testing tests passed |
| `CmuxControlSocket` package | 278 tests in 41 suites passed |
| Unsigned Debug `cmux` app build | Pass |
| `scripts/fork-overlay-audit.sh` | Pass |
| `tests/test_nightly_universal_build.sh` | Pass |
| `tests/test_ci_self_hosted_guard.sh` | Pass |
| pbxproj normalize/check | Pass |
| localization/schema JSON parsing | Pass |
| `git diff --check` | Pass |
| `actionlint` | Same 15 ShellCheck findings as upstream `v0.64.20`; no fork delta |

The app and test builds use `CMUX_SKIP_ZIG_BUILD=1` with the exact cached
GhosttyKit because the local Ghostty CLI helper Zig phase is not part of this
source-parity proof.

## Workflow record

`plans/fork-overlay-cleanup/UPSTREAM-V06420-WORKFLOW-NOTES.md` records:

- All 13 workflows modified by the fork.
- Every upstream trigger, publication step, profile check, tag mutation, and
  infrastructure job intentionally disabled, gated, or replaced.
- The four-job upstream nightly architecture and its compilation cache,
  unsigned artifact transfer, signing/notarization, dSYM, Sparkle, and remote
  daemon paths.
- The TestFlight history, path-gating, assignment-only retry, and scheduled
  beta model worth studying later.
- Exact comparison commands and follow-up questions.

No v0.64.20 workflow file was deleted. Most upstream workflow machinery is
retained for study; credentialed upstream infrastructure is repository-gated.

## Remaining release proof

These are not source-parity gaps:

1. Push the local Bonsplit commit to a branch reachable by the parent
   repository before any shared branch or release build references it.
2. Push the prepared parent branch and let fork CI run on GitHub infrastructure.
3. Build, sign, notarize, and install a candidate without replacing the current
   live app until the user explicitly chooses to dogfood it.
4. Exercise authenticated Codex/Claude restore, Privacy Frost, file-copy,
   Task Manager, workspace placement, and updater behavior in the candidate.
5. Only then prepare version/build numbers and dispatch nightly or stable
   release workflows.

No push, tag, workflow dispatch, public release action, app restart, or live-app
replacement was performed during this parity pass.
