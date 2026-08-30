# cmux Mochi v0.64.22 parity validation matrix

This file records evidence from the exact clean-trunk candidate. Do not copy
results from another worktree, branch, app bundle, or embedded CLI. Every test
run must record a positive executed count; a successful invocation with zero
tests is a failure.

Candidate commit: `1cb18b3866a993ea5d815b424c2c9e3f143c3975`

The later evidence-only record update does not change executable or test
behavior.

<!-- parity-features:start -->
| Feature | Automated command or selector | Executed result | Tagged candidate journey | Result |
| --- | --- | --- | --- | --- |
| `session.force-quit-continuity` Force-quit session continuity | `SessionPersistenceTests/testMetadataAutosavePreservesCapturedScrollbackForForceQuitRecovery`; `scripts/test-force-quit-session-continuity.sh parity-final` | Exact persistence selector passed; the hard-kill harness passed in two complete independent runs. | Seed markers and prompt, wait for autosave, SIGKILL, relaunch and verify; add a second marker/prompt set and repeat. | Tagged `parity-final` retained both complete marker ranges and prompts after both hard-kill relaunches in each run. |
| `agent.resume-continuity` Agent resume continuity | `SessionRestorableAgentSnapshotPermissionModeTests`; `AgentSessionAutoResumeSwiftTests`; focused persistence alias selectors | All selectors passed in the 181-test app-host aggregate. | Restore persisted agent metadata and inspect session identity, prompt, CWD, permission mode, alias choice, and opt-in resume decision. | Candidate app-host journey passed; it did not launch a live third-party agent provider. |
| `placement.adaptive-right` Adaptive right-side placement | `WorkspaceRightSidePlacementPlannerTests`; exact Markdown and file-preview route selectors | Planner and route selectors passed in the 181-test app-host aggregate. | Open Browser, Markdown, Artifact, file preview, and custom sidebar beside a full-width source, then repeat. | Tagged Browser, Markdown, Artifact, and validated custom-sidebar opens reused the aligned right pane; app-host file routes passed. |
| `pane.zoom-persistence` Pane zoom persistence | `PaneZoomSessionPersistenceTests` | All 3 app-host tests passed. | Maximize a non-leading pane, quit the tagged app, relaunch, and compare pane identity and topology. | Tagged command-palette maximize restored the same stable panel, focus, and split topology. |
| `updater.opaque-popover` Opaque update popover | `UpdatePillPopoverResizeTests` | Both updater UI tests passed. | Resolve the AppKit host background in light and dark appearance and exercise the tagged update-pill debug path. | Host is layer-backed and opaque with dynamic `windowBackgroundColor`; a human visual sign-off was not claimed. |
| `conductor.atomic-submit` Atomic submit | `CMUXCLISendSubmitWaitTests` | Suite passed in the 181-test aggregate and five consecutive isolated six-test runs. | Submit a literal separator fixture once through the tagged embedded CLI to an explicit surface. | Tagged `parity-final` sent literal text plus Enter atomically without shell reinterpretation. |
| `conductor.agent-settle-wait` Agent settle wait | `CMUXCLISendSubmitWaitTests` | Bounded wait, timeout, unsupported, and error paths passed. | Submit to the tagged agent surface, observe acknowledgement, then wait for the same target to settle. | Tagged CLI saw `CMUX_WAIT_ACK_CONFIRMED` and returned only when the target reached Ready. |
| `conductor.live-job-guard` Live foreground-job guard | `ControlSurfaceSendGuardTests` | Guard policy and force override selectors passed. | Start `sleep 60` with force, then attempt an ordinary submit to that exact tagged surface. | Ordinary submit was rejected with `live_foreground_job`; explicit cleanup control input remained available. |
| `capture.workspace` Workspace screenshot | `WorkspaceScreenshotParityTests`; control execution-policy selectors | Composite and focus-preservation selectors passed. | Create and open an Artifact, capture the tagged selected workspace, and inspect the output file. | Capture was non-empty, contained the Artifact overlay, and did not change selected workspace. |
| `sentry.startup-policy` Sentry startup policy | `MacSentryStartupPolicyTests`; `CMUXCLISentryTelemetryRegressionTests` | Isolated three-case Sentry matrix and app-host regressions passed. | Verify fork DSN and Debug, Nightly, and Release policy inputs; launch tagged Debug diagnostically. | Fork identity and DSN passed; tagged Debug used the intended no-emission policy. |
| `privacy.frost` Privacy Frost | Focused privacy persistence, row, snapshot, observation, menu, and control-context selectors | All focused privacy behaviors passed. | Toggle workspace and inherited group privacy, restore, render the complete row, preserve its menu, and attempt control routing. | Candidate app-host journey proved persistence, full-row redaction with no fixture text leak, menu access, and private-route rejection. |
| `mobile.account-free-pairing` Account-free mobile pairing | DeviceLink and mobile packages; `MobilePairingFailureTests`; `OnboardingConnectionPhaseTests`; `MobilePairingConnectionTransitionTests`; two signed-out QR UI selectors | Pending final-candidate pairing feedback selector rerun. | Cold-pair simulator and signed physical iPhone by Tailscale QR without Stack credentials; repeat with Tailscale unavailable and confirm actionable guidance plus a stable progress surface. | Pending final-candidate simulator and physical-device sign-off. |
| `mobile.reconnect-continuity` Mobile reconnect continuity | Focused mobile packages; `OnboardingConnectionPhaseTests`; `scripts/mobile-devicelink-e2e.sh` | Pending final-candidate reconnect-progress selector and E2E rerun. | Cold relaunch phone and Mac host after pairing, verify visible reconnect progress, then verify identity adoption, reconnect, and workspace sync. | Pending final-candidate simulator and physical-device sign-off. |
| `welcome.catalog` Welcome catalogue | `CMUXCLIWelcomeRegressionTests` | Welcome regression suite passed. | Run tagged `welcome` and audit every advertised Mochi claim against the ledger. | Tagged output lists only present required behaviors and the no-Pro policy. |
| `task.resource-monitor` Task Manager and footer | Focused Task Manager resource, surface, and persistence selectors | All resource and surface parity selectors passed. | Observe footer, open and reopen Task Manager, check full-area portal behavior, save, and restore. | Tagged menu opened the reusable Task Manager; app-host proof covered process data, portal hiding, footer visibility, and persistence exclusion. |
| `artifacts.panes` Artifact panes | `ArtifactStoreTests`; mobile artifact suites | Store, rendering, revision, provenance, and mobile artifact selectors passed. | Create, list, and open a tagged Artifact, then include it in a workspace capture. | Tagged Artifact opened in a native pane and appeared in the composite capture. |
| `files.backed-tab-actions` File-backed tab actions | `WorkspaceTabPathActionsTests` | All action-targeting selectors passed. | Exercise Reveal, Copy File, and Copy Path models for file preview, file URL, Artifact, and directory inputs. | Candidate app-host journey proved correct targets; a manual context-menu click was not claimed. |
| `navigation.reopen-closed` Reopen last closed | `ReopenLastClosedTests` | History, stable identity, and ordering selectors passed. | Create a second tagged surface, close it, invoke reopen-last-closed, and compare topology. | Surface count returned from one to two and history restored the closed surface. |
| `navigation.sidebar-spring-load` Sidebar drag targeting and selected-set transfer | `SidebarBonsplitWorkspaceSpringLoadTests`; `SidebarWorkspaceDropPlannerTests`; `WorkspaceGroupTests`; focused multi-selection drag coverage | Pending final-candidate highlight, fresh-group, and selected-set selector rerun. | Shift-select multiple sidebar tabs, drag the set across existing workspaces and a newly created group, and verify the hovered target highlights before the drop. | Pending final-candidate human pointer and behavior-level sign-off. |
| `sidebar.render-stability` Sidebar render stability | `SidebarLazyLayoutScaleTests`; `SidebarPointerInteractionScaleTests`; mutation scheduler selectors | Strict hidden-fixture scale suite passed 6 of 6; scheduler selectors passed. | Drive bounded visible-row and stationary-pointer churn against a hidden native sidebar fixture. | Probes converged and the fixture-specific root layout reentry counter stayed zero; inherited AppKit geometry warnings remain. |
| `skills.bundled` Bundled skills | `CmuxSkillsBundleInstallerTests`; resource audit | Installer ownership/update selectors passed; 20 of 20 bundled skill directories contained non-empty `SKILL.md`. | Audit the final-source bundle and exercise managed, modified, and unmanaged install cases. | Candidate bundle and installer contract passed. |
| `shell.safe-resume-aliases` Safe resume aliases | Focused persistence, permission-mode, and auto-resume selectors | All alias and fallback selectors passed. | Inspect `cc`, `ccy`, `cx`, and `cxy` in a tagged shell. | All four resolved as functions and expanded to guarded resume implementations. |
| `fork.no-pro-upsell` No Pro upsell | `ProUpgradePresentationPolicyTests` | Both tests passed across three Mochi bundle identities. | Audit fork account policy and every upgrade-action presentation path. | Explanatory fork row remains while unpurchasable upgrade actions are suppressed. |
| `ops.fork-release-overlay` Fork release overlay | `scripts/fork-overlay-audit.sh`; workflow contracts; universal Release build | Fork identity, workflow ownership, build-number, and test-wiring checks passed. | Build unsigned arm64 and x86_64 Release products from final source and inspect app and CLI slices. | Local release gate completed without dispatching Nightly or TestFlight. |
<!-- parity-features:end -->

Non-blocking backlog: the iOS Markdown/Artifact renderer exists, but the tested
chat journey does not yet expose a discoverable, reliable viewer entry point.
This usability follow-up does not block this release candidate.

## Candidate-wide gates

<!-- parity-gates:start -->
| Gate | Command | Result |
| --- | --- | --- |
| Test files wired | `scripts/lint-pbxproj-test-wiring.sh` | Passed: 662 test files wired. |
| Fork parity suite | `scripts/test-fork-parity.sh` | Passed focused packages and 181 of 181 app-host tests; isolated Sentry passed 3 of 3 and strict sidebar scale passed 6 of 6. |
| Unit target compiles | `xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-parity-unit build` | Passed: `** BUILD SUCCEEDED **`. |
| Tagged Debug app | `CMUX_SKIP_ZIG_BUILD=1 CMUX_RELOAD_NO_GLOBAL_CLI_LINKS=1 scripts/reload.sh --tag parity-final` | Built and launched; tagged force-quit, CLI, pane, Task Manager, Artifact, and navigation journeys executed against its explicit socket. |
| Universal Release build | `scripts/build-release-universal.sh --derived-data-path build-universal-parity-final`; `lipo -archs` on app, standalone CLI, and bundled CLI | Passed: all three executables contain `x86_64 arm64`; bundle `com.cmux-mochi`, version `0.64.22`, build `122`. |
| Fork overlay | `scripts/fork-overlay-audit.sh` | Passed: deterministic fork identity, fork-owned workflows and Sentry, 662 test files wired, 25-row terminal ledger, and valid project file. |
| Release pre-tag | `scripts/release-pretag-guard.sh` | Passed from candidate `1cb18b3866`: overlay and focused packages passed; app-host parity 181/181, isolated Sentry 3/3, strict sidebar stress 6/6, validator 11/11, build monotonicity, 24 feature rows, 7 release gates, and 5 mobile journeys all passed. |
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
| Account-free pairing and reconnect units | `swift test` for `CMUXMobileCore`, `DeviceLinkKit`, `CmuxMobilePairedMac`, `CmuxMobileShellModel`, and `CmuxMobileSupport`; full `CmuxMobileShell` baseline comparison | Passed 714 tests across five focused packages. Full `CmuxMobileShell` ran 991 tests in 95 suites with 15 inherited timing issues; representative failures reproduced unchanged on exact base `287e4ff3c7`. |
| Signed-out QR onboarding | `cmuxUITests/testSignedOutOnboardingOpensQRScannerWithoutSignIn` on iPhone 17 simulator | Passed as part of a 2-test UI run. |
| Tailscale and QR Setup Help | `cmuxUITests/testSetupHelpUsesTailscaleQRAndNoAccountJourney` on iPhone 17 simulator | Passed as part of the same 2-test UI run. |
| Simulator cold pair and reconnect | `scripts/mobile-devicelink-e2e.sh --tag parity-final --simulator 'iPhone 17'` | Passed cold install: DeviceLink v3, no Stack credentials, persisted pairing, workspace sync, cold relaunch, identity adoption, reconnect, and resync. |
| Physical iPhone cold pair and reconnect | `scripts/mobile-devicelink-e2e.sh --tag parity-final --device` | Passed signed cold install on iPhone 17 Pro Max: Tailscale DeviceLink v3, no Stack credentials, persisted pairing, workspace sync, cold relaunch, identity adoption, reconnect, and resync. |
<!-- parity-mobile:end -->
