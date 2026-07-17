# cmux Mochi v0.64.19 parity report

Date: 2026-07-17

## Result

The source port from upstream `v0.64.19` to the shipped Mochi behavior at `v0.64.173` is complete. Every feature marked `port` in the replay ledger is present on `mochi/on-v0.64.19`; no source-parity item is blocked.

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

## Known baseline failures retained

- `SessionPersistenceTests`: 9 agent-hook/Hermes cases.
- `RestorableAgentSessionIndexTests.testKilledSessionWithDeadProcessDoesNotRestore`.
- `TerminalControllerSocketSecurityTests.v1CommandsRejectCustomSidebarNames` and the other recorded base-profile socket-security failure.
- `testRemotePTYBridgeRoutesMovedSurfaceToCurrentWorkspace`.
- The recorded Browser Portal omnibar and macOS 26.5 Terminal/Ghostty base-profile failures from queue item 0.

No additional unique failure was introduced by the parity port.
