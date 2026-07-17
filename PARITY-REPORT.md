# cmux Mochi v0.64.19 parity report

Date: 2026-07-17 (addendum: same day, post-dogfood)

## Result

The source port from upstream `v0.64.19` to the shipped Mochi behavior at `v0.64.173` is complete. Every feature marked `port` in the replay ledger is present on `mochi/on-v0.64.19`; no source-parity item is blocked.

**Post-dogfood addendum (2026-07-17):** the first live dogfood of the
parity-review build caught a real gap this report's original validation missed —
`ops.fork-identity` was only partially ported. The tagged debug app bound the shared
`/tmp/cmux-debug.sock` because `SocketPathMarkerFiles` (and ~300 other identity
references) still carried upstream `com.cmuxterm.*` values. A follow-up
release-values audit found five fork release-lane guards silently reverted to
upstream versions. The resulting review rounds are consolidated into the two
implementation commits described below.

This work is prepared but not shipped. No push, tag, workflow dispatch, release, publication, or version bump was performed. The project remains at `MARKETING_VERSION = 0.64.19` and `CURRENT_PROJECT_VERSION = 99` in every build configuration.

| Role | Ref | Commit |
| --- | --- | --- |
| Upstream base | `v0.64.19` | `1c22c55643` |
| Shipped parity oracle | `v0.64.173` | `6cc68ba8cc` |
| Prepared branch | `mochi/on-v0.64.19` | local only |

## Queue result and commits

### 0. VS Code convergence verification

The already-ported per-workspace serve-web/full-workbench implementation was reverified before the remaining ports:

- `OmnibarAndToolsTests`: 62 executed; 61 passed; 1 base-known Browser Portal omnibar failure.
- `BrowserPanelSessionRestoreTests`: 2 executed; 2 passed.
- `TerminalControllerSocketSecurityTests`: 43 executed; 41 passed; 2 base-known failures.
- `TerminalAndGhosttyTests`: 193 executed; 177 passed; 16 failures reproduced as the macOS 26.5 base profile rather than port regressions.

The convergence implementation is carried by `6cd65436f7`, `2e118c0190`, and `9c4fbb1299`.

### 1. Privacy Frost

- `b14ec64de5 feat(privacy): port workspace frost controls`
- `f492e4ddc6 fix(privacy): match shipped frost teardown semantics`

Workspace and group frost state, inherited effective privacy, persistence, sidebar behavior, snapshot policy, and socket context match the shipped tag. The review correction is included: frost is visual privacy and does not stop the workspace serve-web server. `TabManager.swift` retains the tag's single registry stop in `closeWorkspace` only.

Validation:

- `TabManagerWorkspacePrivacyTests`: 12/12 passed.
- Combined Swift privacy selection: 112 tests across 4 suites; 2 assertions failed only in the known base test `testRemotePTYBridgeRoutesMovedSurfaceToCurrentWorkspace`.
- Earlier focused privacy/package gates: 81 passed (12 XCTest and 69 Swift).
- Nine changed privacy localization keys were checked in English and Japanese against the tag.

### 2. Tag-sync hygiene

- `8817f7a984 test(sync): port parity suite hygiene`

The shipped Conductor skill documents, right-sidebar isolation fix, remote-suite serialization, and CI isolation were reconciled onto this branch. The Swift file-length budget was deliberately regenerated only after the merged source tree was final.

### 3. Agent resume continuity

- `2c41599ce6 feat(session): port agent resume continuity`
- `50f851e0b5 fix(session): match shipped resume metadata`

The boolean setting is replaced by shipped `Off`/`Medium`/`Full` semantics; legacy `false` migrates to Off; ambiguous restored metadata remains safe; Medium replays scrollback and prefills without submitting; Full submits without replay. The existing lenient Codex restorability rule and cxy/ccy alias behavior remain intact. The fixup restores the enum documentation, exact schema prose, `agentResumeCommandStyle` schema surface, and both message catalogs from the tag.

Validation:

- `AgentSessionAutoResumeSettingsTests`: 21/21 passed.
- `RestorableAgentSessionIndexTests`: 25/26 passed; only the declared base-known `testKilledSessionWithDeadProcessDoesNotRestore` failed.
- `SessionPersistenceTests`: 145/154 unique tests passed; the 9 known agent-hook/Hermes failures produced 22 assertions.
- Combined selection: 201 executed with 23 known-base assertion failures and no new unique failure.
- Focused evolved auto-resume tests: 28/28 passed; alias behavior: 6/6 passed.

### 4. Workspace capture

- `7f0c36fc5a feat(capture): port workspace screenshot control`
- `56aed28601 fix(capture): expose surface imaging in release`

The V2 surface-image pipeline, surface screenshot/ingest policy, `workspace.screenshot`, socket-worker dispatch, and `capture-workspace` CLI are present. The Release fixup makes `debugCopyIOSurfaceCGImage()` available outside `#if DEBUG`, byte-matching the oracle and allowing the universal Release build to compile.

Validation:

- Focused execution-policy test: 1/1 passed.
- Full `CmuxControlSocket` after all corrections: 254/254 passed in 39 suites.
- Universal Release build completed after proving both architecture slices.

### 5. Welcome catalog and artifact command correction

- `e438808aeb feat(welcome): port audited Mochi feature catalog`
- `a082258aaa feat(artifacts): port open and list parity`

The Welcome catalog is copied from the shipped tag and its artifact claim is now exact: `cmux artifact new/open/list`. The missing `artifact open` and `artifact list` CLI commands, socket methods, worker execution-policy entries, contract documentation, and regression coverage were ported from the tag rather than shrinking the shipped claim.

Validation:

- Welcome regression: 2/2 passed.
- Artifact open/list execution-policy regression: 1/1 passed after first proving the test red with 2 failures.
- Focused artifact + Welcome gate: 32/32 passed in 2 suites.
- The final tagged bundled CLI returned zero for `artifact help` and `welcome`; help advertises new/open/list and Welcome contains the exact shipped artifact line.

## Feature ledger

Every ledger entry whose disposition is `port` is done:

| Feature | Status | Primary prepared commit(s) |
| --- | --- | --- |
| `placement.adaptive-right` | done | `c85ac80411` |
| `vscode.extension-profile` | done | `6cd65436f7`, `2e118c0190`, `9c4fbb1299` |
| `navigation.sidebar-spring-load` | done | `55957051df` |
| `agent.restore-no-autostart` | done | `1faaddadcc` |
| `agent.resume-modes` | done | `2c41599ce6`, `50f851e0b5` |
| `agent.scrollback-continuity` | done | `2c41599ce6` |
| `agent.lifecycle-events` | done | `2c41599ce6` |
| `conductor.atomic-submit` | done | `977504fec5` |
| `conductor.event-confirmed-submit` | done | `f87d291f79` |
| `conductor.live-job-guard` | done | `3b65b79317` |
| `capture.workspace` | done | `7f0c36fc5a`, `56aed28601` |
| `privacy.frost` | done | `b14ec64de5`, `f492e4ddc6` |
| `pane.zoom-persistence` | done | `ade84640e4` |
| `updater.ui-fixes` | done | `6f6e15d542` |
| `artifacts.repository` | done | `fd1da4da81`, `a082258aaa` |
| `artifacts.surface` | done | `fd1da4da81`, `a082258aaa` |
| `artifacts.renderer` | done | `fd1da4da81` |
| `artifacts.runtime-bridge` | done | `fd1da4da81` |
| `artifacts.storage-revisions` | done | `fd1da4da81` |
| `skills.bundled` | done | `bd451db9c4`, `8817f7a984` |
| `ovm.integration` | done | `e438808aeb` |
| `security.passkeys-status` | done | `e438808aeb` |
| `ops.fork-identity` | done | `0046e6416e`, `42326da241` |
| `ops.release-lanes` | done | `a6706c43a4`, `6907b9eb11` |
| `ops.submodule-ownership` | done | `42326da241` |
| `ci.release-build-shape` | done | `a6706c43a4`, `6907b9eb11` |
| `welcome.catalog` | done | `e438808aeb`, `a082258aaa` |

The ledger's `upstream-owned`, `retire`, and explicitly deferred historical features are outside the requested `port` checklist and were not reimplemented.

## Final validation

| Gate | Result |
| --- | --- |
| `bash scripts/fork-overlay-audit.sh` | passed |
| `Packages/macOS/CmuxWorkspaces` `swift test` | 151/151 passed in 22 suites |
| `Packages/macOS/CmuxControlSocket` `swift test` | 254/254 passed in 39 suites |
| Swift file-length budget | regenerated from 4,760 Swift files / 1,006,114 lines; budget respected |
| Localization/data parsing | `Localizable.xcstrings`, schema, English messages, and Japanese messages parsed successfully |
| Version invariant | 0.64.19 / 99 in every configuration |
| Universal Release build | passed; app and bundled CLI each report `x86_64 arm64` via `lipo` |
| Tagged Debug build | `parity-review` passed with `** BUILD SUCCEEDED **` |
| Diff hygiene | `git diff --check` passed before report commit |

Localization audit details:

- Privacy Frost: 9 changed catalog keys have English and Japanese values copied from the oracle.
- Resume settings: Swift catalog entries, schema descriptions, and `web/messages/en.json` plus `web/messages/ja.json` match the oracle, including `agentResumeCommandStyle`.
- Artifact CLI/help, CLI contract, and Welcome text are verbatim from the oracle. These raw CLI/docs surfaces do not have corresponding oracle message-catalog keys.

## Review builds

Universal Release app:

`/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06419/build-universal/Build/Products/Release/cmux Mochi.app`

Tagged Debug app for morning review:

`/Users/timapple/Library/Developer/Xcode/DerivedData/cmux-parity-review/Build/Products/Debug/cmux Mochi DEV parity-review.app`

The tagged app was built but not launched.

## Deliberately skipped live or shipping checks

These are validation limits, not blocked source ports:

- No authenticated VS Code serve-web install/trust/sign-in dogfood.
- No authenticated agent-provider restore, resume, or lifecycle dogfood.
- No live Privacy Frost visual or capture-redaction dogfood.
- No live workspace screenshot/socket CLI dogfood because the final tagged app was not launched.
- No signed passkeys, notarization, appcast, or public nightly proof.
- No push, tag, workflow dispatch, version bump, release, or other shipping-lane execution, per the hard rule.

## Dogfood and identity addendum (2026-07-17)

Live dogfood of the tagged parity-review build verified end-to-end:

- Agent resume (Medium): full scrollback replay, resume command prefilled with the
  `cc` alias and not submitted, session resumed with transcript and context intact
  after quit/relaunch.
- First-run Welcome catalog, the live-job send guard, workspace/session restore,
  and `capture-workspace` all exercised live.
- After the identity fix: the tagged app binds `/tmp/cmux-debug-parity-review.sock`
  (shared `/tmp/cmux-debug.sock` no longer used) and `scripts/cmux-debug-cli.sh`
  works as designed.

Fork identity and ownership (`bcb65dc479`): the runtime, updater, URL,
display-name, automation, APNs, and localization fix waves are consolidated into
one commit. Every renamed identity either byte-matches the v0.64.173 oracle or is
a functional no-oracle site (updater dev/staging gating, stable-defaults device-id
inheritance, client-capability fallback, APNs prod routing). References the shipped
tag deliberately keeps on upstream ids remain unchanged. Manual update recovery
coverage now pins the complete Mochi stable/nightly URLs, and the restored app-name
strings include Japanese `cmux Mochi` translations.

CI and release overlay (`fd4f25b992`): `release-pretag-guard.sh` (fork-overlay
audit + exact-HEAD CI check + `--build`), `bump-version.sh` (patch-by-default +
appcast marketing baseline), `verify-app-bundle-channel-metadata.sh` (cmux Mochi
names), the fork CI runner/helper topology, and the UI-regressions lane are restored
as one commit. Upstream's scheduled `cmux-tui-nightly.yml` cron remains disabled
fork-side. The fork-overlay audit asserts runtime identity constants, both nightly
landing-page implementations, and resolves repository paths independently of the
caller's working directory. `test_ci_sparkle_build_monotonic.sh` points at the fork
appcast and correctly remains red on build 99 < published 118 until an explicitly
approved pre-release bump.

Validation of the addendum: CmuxSettings 252/252, CmuxControlSocket 254/254,
CmuxUpdater 77/77, web APNs 28/28, `tests/test_cli_socket_autodiscovery.py` all
PASS, fork-overlay audit green, tagged Debug rebuild + live socket dogfood green.
App-suite triage on this machine (macOS 26.5): 26 failures shared with the
v0.64.173 baseline tree, 6 upstream-new Freestyle-sshd restore tests failing
identically pre-fix, 0 regressions attributable to the identity fix.

Codex adversarial validation (rounds 1–3, visible cmux pane, tag-grounded)
drove three further fix waves that are now folded into the two commits above:

- Round 1: repo-URL identity class (36 sites incl. the updater fallback appcast
  feed pointing at upstream) and the workflow-guard BLOCKER — upstream guard
  tests plus a stripped actionlint runner label guaranteed red CI against the
  fork's workflows. Fixed by re-porting the fork ci.yml overlay (fork app names
  in release-build/tests-build-and-lag, the ui-regressions job, main-push
  cancel), restoring the tag guard tests adapted to upstream's relocated helper
  build (swift-package-tests), and restoring actionlint.yaml (+ upstream's
  tart-canary).
- Round 2: app display-name class inside CI-called scripts (37 sites;
  run-display-ui-regressions.sh and verify-main-thread-ca-transactions.sh
  would have aborted tests-build-and-lag), docs/ci-runners.md URLs, APNs
  host-grouping fixtures, guard hardening (tart-* forbidden in runner
  selection; sdk-lane re-asserts SDK-15 slices, artifact name, producer
  dependency).
- Round 3: UpdateManualDownloadRecovery stable/nightly downloads pointed at
  upstream's releases (BLOCKER), the nightly web landing page likewise, four
  reverted "cmux Mochi" UI strings in Localizable.xcstrings, and the
  remaining ci-runners break-glass commands.

Rewritten-tip validation: `InstallWatchdogTests` 11/11, CmuxSettings socket
control 29/29, APNs 28/28, self-hosted runner guard, release SDK lane, nightly
universal guard, fork-overlay audit, profiling launcher, and CLI socket
autodiscovery all pass. The tagged `fork-cleanup` Debug build succeeded from the
rewritten commits. A standalone full-workflow actionlint run still reports inherited
shellcheck findings in byte-identical workflow content (plus unrelated workflows);
the cleanup introduced no workflow delta relative to the pre-squash backup. The
Sparkle monotonic guard intentionally reports build 99 <= published 118 until a
separately approved version bump.

New known issues catalogued (not parity gaps):

- First-run `cmux welcome` leaves `PanelShellActivityState` stuck at
  `commandRunning` until the next command, so the first automated `send` to a
  fresh install's first terminal is refused by the live-job guard. All wiring is
  byte-identical to the shipped tag; likely a shipped bug — pending empirical
  confirmation on a shipped build.
- `tests_v2/test_config_settings_sources_and_sync.py` cannot compile its probe on
  this base (`ConfigSource.swift` now imports `CmuxFoundation`); pre-existing
  upstream harness breakage, fails identically without the identity fix.
- Local machine only: cold-cache zig builds fail against Xcode 26's SDK
  (libSystem.tbd lacks `arm64-macos`); workaround recorded in agent memory.

## Known baseline failures retained

- `SessionPersistenceTests`: 9 agent-hook/Hermes cases.
- `RestorableAgentSessionIndexTests.testKilledSessionWithDeadProcessDoesNotRestore`.
- `TerminalControllerSocketSecurityTests.v1CommandsRejectCustomSidebarNames` and the other recorded base-profile socket-security failure.
- `testRemotePTYBridgeRoutesMovedSurfaceToCurrentWorkspace`.
- The recorded Browser Portal omnibar and macOS 26.5 Terminal/Ghostty base-profile failures from queue item 0.

No additional unique failure was introduced by the parity port.
