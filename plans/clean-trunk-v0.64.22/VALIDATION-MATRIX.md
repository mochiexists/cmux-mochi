# cmux Mochi v0.64.22 parity validation matrix

This file records evidence from the exact clean-trunk candidate. Do not copy
results from another worktree, branch, app bundle, or embedded CLI. Every test
run must record a positive executed count; a successful invocation with zero
tests is a failure.

Candidate commit: `pending`

<!-- parity-features:start -->
| Feature | Automated command or selector | Executed result | Tagged candidate journey | Result |
| --- | --- | --- | --- | --- |
| Force-quit session continuity | `SessionPersistenceTests/testMetadataAutosavePreservesCapturedScrollbackForForceQuitRecovery` | Exact selector passed in the 135-test app-host aggregate. | Seed 240 markers plus a prompt, wait past autosave, SIGKILL, relaunch and verify first/middle/last/prompt; repeat with a second marker set. | Passed twice on tagged `parity-recovery`; both relaunches retained both marker ranges and prompts. |
| Adaptive right-side placement | `WorkspaceRightSidePlacementPlannerTests`; exact Markdown and file-preview route selectors | 7 planner, 1 control-Markdown, and 2 click-route tests passed. | Open Browser, Markdown, Artifact, file preview, and custom sidebar beside a full-width source, then repeat each open. | Tagged Browser, Markdown, Artifact, and temporary validated custom-sidebar opens reused pane 6; exact app-host file-preview/Markdown routes passed. |
| Pane zoom persistence | `PaneZoomSessionPersistenceTests` | 3 app-host tests passed. | Maximize a non-leading pane, quit the tagged app, relaunch, and compare pane identity/topology. | Tagged command-palette maximize persisted and restored stable panel `78299116-4114-42B4-A870-3F78D5E347E5` with the same focused panel and split topology. |
| Opaque update popover | `UpdatePillPopoverResizeTests` | 2 updater UI tests passed. | Inspect the AppKit popover host's resolved dynamic background and tagged update-pill path. | Host is layer-backed and opaque with dynamic `windowBackgroundColor` for light/dark resolution; tagged Debug menu exposes the live pill journey. |
| Atomic submit and wait | `CMUXCLISendSubmitWaitTests` | Suite passed in the 135-test app-host aggregate. | Use the tagged embedded CLI against its explicit socket; send a literal separator fixture, submit once, verify target acknowledgement, then wait for settle. | Tagged literal submit passed; `--wait` observed `CMUX_WAIT_ACK_CONFIRMED` on the targeted agent and returned at Ready. |
| Sentry startup policy | `MacSentryStartupPolicyTests`; `CMUXCLISentryTelemetryRegressionTests` | Both app-host suites passed, including the three-case CI matrix. | Verify built Debug, tagged Debug, Nightly, and Release policy inputs; launch tagged candidate with diagnostic logging. | Fork DSN/bundle policy checked; tagged Debug launched under the intended no-emission Debug policy. |
| Privacy Frost | Focused privacy selectors listed by `scripts/test-fork-parity.sh` | 5 app-host behavior tests passed. | Toggle workspace and inherited group privacy, inspect complete-row redaction, capture, quit, and relaunch. | Non-sensitive app-host journey proved persistence/inheritance, complete-row frost with no text leak, live menu action, observation refresh, and private-route rejection. |
| Welcome catalogue | `CMUXCLIWelcomeRegressionTests` | Suite passed in the 135-test app-host aggregate. | Run `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh welcome` and compare every claim to this ledger. | Tagged bundled CLI output was captured and audited; it lists only present Mochi behaviors and the no-Pro policy. |
| Task Manager and footer | Focused Task Manager selectors listed by `scripts/test-fork-parity.sh` | 22 resource tests plus 5 surface parity tests passed. | Observe live footer values, open/reopen Task Manager, verify full-area page and hidden terminal portal, quit/relaunch, and confirm no special surface restoration. | Tagged Window menu opened/reopened Task Manager; app-host journey proved one reused process surface, full-area portal hiding, always-visible footer policy, and exclusion from the saved session. |
| No Pro upsell | `ProUpgradePresentationPolicyTests` | 2 tests passed, including 3 Mochi bundle identities. | Audit fork account policy and all upgrade-action presentation paths. | Mochi identities retain the explanatory account row and suppress unpurchasable upgrade actions; tagged Welcome states the same policy. |
<!-- parity-features:end -->

## Candidate-wide gates

<!-- parity-gates:start -->
| Gate | Command | Result |
| --- | --- | --- |
| Test files wired | `scripts/lint-pbxproj-test-wiring.sh` | Passed: 658 test files wired. |
| Fork parity suite | `scripts/test-fork-parity.sh` | Passed with positive per-selector evidence: 14 package tests, 26 XCTest cases, and 135 Swift Testing cases. |
| Unit target compiles | `xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-parity-unit build` | Passed: `** BUILD SUCCEEDED **`. |
| Tagged Debug app | `CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag parity-recovery` | Built and launched; initial socket wait was blocked by a visible Keychain approval dialog, then the tagged socket returned `PONG`. |
| Fork overlay | `scripts/fork-overlay-audit.sh` | Passed, including fork identity determinism, 658-file test wiring, and the terminal 12-row ledger. |
| Release pre-tag | `scripts/release-pretag-guard.sh` | Pending |
| Source hygiene | `git diff --check` | Passed. |
<!-- parity-gates:end -->

## Device and external evidence

Simulator and physical-iPhone DeviceLink E2E remain separate from the desktop
feature proofs. They must be rerun against the same candidate commit before a
combined macOS/iOS release claim. A local source or macOS build does not satisfy
either device gate.

<!-- parity-mobile:start -->
| Mobile journey | Command or selector | Result |
| --- | --- | --- |
| Account-free pairing and reconnect units | `swift test` for `CMUXMobileCore`, `DeviceLinkKit`, `CmuxMobilePairedMac`, `CmuxMobileShellModel`, and `CmuxMobileSupport`; full `CmuxMobileShell` baseline comparison | Passed 714 tests across the five focused packages. Full `CmuxMobileShell` ran 991 tests/95 suites with 15 issues in inherited timing suites; representative failures reproduced unchanged on exact base `287e4ff3c7`. |
| Signed-out QR onboarding | `cmuxUITests/testSignedOutOnboardingOpensQRScannerWithoutSignIn` on iPhone 17 simulator | Passed as part of a 2-test UI run. |
| Tailscale and QR Setup Help | `cmuxUITests/testSetupHelpUsesTailscaleQRAndNoAccountJourney` on iPhone 17 simulator | Passed as part of the same 2-test UI run. |
| Simulator cold pair and reconnect | `scripts/mobile-devicelink-e2e.sh --tag parity-recovery --simulator 'iPhone 17'` | Passed cold install: DeviceLink v3, no Stack credentials, persisted pairing, workspace sync, cold relaunch, identity adoption, reconnect, and sync. |
| Physical iPhone cold pair and reconnect | `scripts/mobile-devicelink-e2e.sh --tag parity-recovery --device` | Passed cold install on the attached iPhone: Tailscale DeviceLink v3, no Stack credentials, persisted pairing, workspace sync, cold relaunch, identity adoption, reconnect, and sync. |
<!-- parity-mobile:end -->
