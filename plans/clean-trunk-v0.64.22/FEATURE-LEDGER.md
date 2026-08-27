# cmux Mochi v0.64.22 parity ledger

This is the acceptance source of truth for the clean-trunk replay. A build, a
large aggregate test count, or the presence of a socket handler is not parity
proof. Every required row must have behavior-level source evidence, a focused
test that executes at least one test, and the live proof named below before a
Nightly or TestFlight candidate can be called parity-complete.

## Status vocabulary

- `ported`: the fork behavior is present on this branch.
- `upstream-equivalent`: current upstream behavior satisfies the same contract.
- `retired`: intentionally excluded from this fork's product contract.
- `missing`: required behavior is absent.
- `in-progress`: implementation or proof is currently incomplete.

Only `ported`, `upstream-equivalent`, and `retired` are terminal states. A
required row in `missing` or `in-progress` blocks parity completion.

## Required behavior inventory

<!-- parity-ledger:start -->
| ID | Required behavior | Source lineage | State | Automated proof | Candidate proof |
| --- | --- | --- | --- | --- | --- |
| `session.force-quit-continuity` | Durable terminal scrollback and agent prompts survive metadata autosave followed by force quit, then remain present across a second force-quit/relaunch cycle. | `852f71b11e`, `9fcf3fba5e` | `ported` | `SessionPersistenceTests/testMetadataAutosavePreservesCapturedScrollbackForForceQuitRecovery` | Passed twice in the tagged app: 240 markers plus prompt, autosave wait, SIGKILL, relaunch, then a second complete marker/prompt cycle. |
| `agent.resume-continuity` | Restored agent sessions preserve working directory, permission mode, session identity, prompts, and opt-in auto-resume behavior without starting agents unexpectedly. | `21b556ae45` plus upstream resume fixes | `in-progress` | `SessionRestorableAgentSnapshotPermissionModeTests`, `AgentSessionAutoResumeSwiftTests`, and focused `SessionPersistenceTests` alias selectors | Pending expanded parity rerun and tagged restore journey. |
| `placement.adaptive-right` | A first beside-open from a full-width source creates a right split; later opens reuse the nearest aligned right pane across supported entry points. | `062e27b120` | `ported` | `WorkspaceRightSidePlacementPlannerTests` plus exact Markdown/file route selectors | Tagged topology proved Browser, Markdown, Artifact, and a temporary validated custom sidebar all reused the aligned right pane; file-preview and Markdown click routes passed in the app host. |
| `pane.zoom-persistence` | Bonsplit pane maximization survives save, quit, and relaunch using stable panel identity rather than regenerated pane identity. | `8293d1d059` | `ported` | `PaneZoomSessionPersistenceTests` | Tagged command-palette maximize stored the focused stable panel ID; normal quit/relaunch restored the same zoomed and focused panel with unchanged split topology. |
| `updater.opaque-popover` | The update-pill popover is opaque in light and dark appearance. | `bd4dcac9bf` | `ported` | `UpdatePillPopoverResizeTests` | AppKit host test proves an opaque dynamic `windowBackgroundColor`, which resolves for both appearances, and the tagged app exposes the update-pill debug journey. |
| `conductor.atomic-submit` | `cmux send --enter` and `--submit` atomically send literal text followed by Enter without shell reinterpretation. | `49f5d90983` | `ported` | `CMUXCLISendSubmitWaitTests` | Tagged CLI submitted a literal-separator fixture to the explicitly targeted surface without reinterpretation. |
| `conductor.agent-settle-wait` | `cmux send --wait` waits for the targeted agent to settle, with bounded timeout and correct unsupported/error behavior. | `815f3b5ab3` | `ported` | `CMUXCLISendSubmitWaitTests` | Tagged CLI returned only after the same targeted agent visibly acknowledged `CMUX_WAIT_ACK_CONFIRMED` and settled to Ready. |
| `conductor.live-job-guard` | Surface-pinned text submission refuses a live non-agent foreground job unless force is explicit, while known agents and idle shells remain usable. | fork L2 socket safety replay | `in-progress` | `ControlSurfaceSendGuardTests` | Pending focused package rerun and tagged guarded-send journey. |
| `capture.workspace` | `workspace.screenshot` captures the selected visible workspace without changing focus and composites terminal, browser, agent, and Artifact renderers into one image. | `c69f9fbd34` | `in-progress` | `WorkspaceScreenshotParityTests` plus control execution-policy tests | Artifact overlay regression fixed; pending tagged mixed-pane screenshot proof. |
| `sentry.startup-policy` | The fork starts Sentry only under its explicit channel/configuration policy and uses the fork project. | `3909e8ccd6` | `ported` | `MacSentryStartupPolicyTests` and `CMUXCLISentryTelemetryRegressionTests` | Built-bundle channel policy and fork DSN were checked; tagged Debug launched with the intended no-emission Debug policy. |
| `privacy.frost` | Workspace/group privacy controls persist, inherit correctly, redact the complete sidebar row, preserve menu access, and keep shipped teardown semantics. | `04bf56f8e5`, `f99cf9836e`, `26a2172ae8`, `c7a1d8d5ef` | `ported` | Focused workspace, sidebar-row, snapshot, observation, context-menu, and control-context privacy suites | App-host journey uses non-sensitive fixtures to toggle workspace/group privacy, restore it, render full-row frost, reject text leaks, preserve the menu action, and block private control routing. |
| `mobile.account-free-pairing` | A signed-out iPhone can discover Setup Help and pair only by QR over Tailscale without Stack credentials or account authentication. | clean-trunk L3-L6 DeviceLink replay | `in-progress` | DeviceLink and mobile focused packages plus `testSignedOutOnboardingOpensQRScannerWithoutSignIn` and `testSetupHelpUsesTailscaleQRAndNoAccountJourney` | Prior simulator and device proof exists at `e8484ef256`; pending rerun at the final candidate SHA. |
| `mobile.reconnect-continuity` | A paired simulator or physical iPhone persists its DeviceLink identity and reconnects after both Mac and phone cold relaunch. | clean-trunk L3-L6 DeviceLink replay | `in-progress` | Focused mobile packages and `scripts/mobile-devicelink-e2e.sh` | Prior simulator and device cold reconnect proof exists at `e8484ef256`; pending rerun at the final candidate SHA. |
| `welcome.catalog` | `cmux welcome` lists only audited Mochi features that are present in this candidate. | `1c23ce721b` | `ported` | `CMUXCLIWelcomeRegressionTests` | Exact output from `CMUX_TAG=parity-recovery scripts/cmux-debug-cli.sh welcome` was audited against this ledger. |
| `task.resource-monitor` | An always-visible CPU/memory footer opens the reusable full-area Task Manager surface; its special selection is ephemeral and excluded from persistence. | `fa93267f31`, `6cf67ada07`, `5776fed431`, `3f64f17a05`, `1b5b758b2b`, `b267867d02`, `2ce5838b3b` | `ported` | `WorkspaceCoreValueTests`, Task Manager resource/surface/persistence suites | Tagged Window menu opened/reopened Task Manager; app-host proofs cover one reusable surface, process data, full-area portal hiding, always-visible resource summary, and zero Task Manager entries in the saved session. |
| `artifacts.panes` | React, HTML, SVG, Mermaid, code, and file artifacts retain provenance, revision history, runtime storage, safe preview rendering, and pane integration. | fork artifact repository and pane replay | `in-progress` | `ArtifactStoreTests` plus existing mobile artifact suites | Store tests restored; pending tagged create/open/list and mixed workspace-capture proof. |
| `files.backed-tab-actions` | File previews, file URLs, and Artifact panes expose Reveal in Finder, Copy File, and Copy Path with correct file/directory targeting. | retained fork tab-path actions | `in-progress` | `WorkspaceTabPathActionsTests` | Pending expanded parity rerun and tagged context-menu proof. |
| `navigation.reopen-closed` | The last closed panel or workspace can be reopened with stable identity and correct history ordering. | retained upstream/fork navigation behavior | `in-progress` | `ReopenLastClosedTests` | Pending expanded parity rerun and tagged shortcut proof. |
| `navigation.sidebar-spring-load` | Hovering a workspace while dragging a session spring-loads that workspace so the visible layout matches the drop target. | `cd7f3e7ab6` | `in-progress` | `SidebarBonsplitWorkspaceSpringLoadTests` | Pending expanded parity rerun and tagged drag journey. |
| `sidebar.render-stability` | Busy sidebars keep update work bounded to visible rows and converge without a self-sustaining render/layout storm. | upstream-equivalent lazy-layout and fork scheduler fixes | `in-progress` | `SidebarLazyLayoutScaleTests`, `SidebarPointerInteractionScaleTests`, and mutation scheduler tests | Pending expanded parity rerun. |
| `skills.bundled` | Bundled cmux skills install on first launch, update only untouched managed copies, and never overwrite user-modified or unmanaged skills. | retained fork skills installer | `in-progress` | `CmuxSkillsBundleInstallerTests` | Dedicated tests restored; pending bundled-resource audit at final candidate SHA. |
| `shell.safe-resume-aliases` | `cc`, `ccy`, `cx`, and `cxy` aliases preserve resume semantics: aliases are used only when permission mode, environment, and non-posture arguments need no replay. | `21b556ae45` | `in-progress` | Focused `SessionPersistenceTests`, `SessionRestorableAgentSnapshotPermissionModeTests`, and `AgentSessionAutoResumeSwiftTests` | Pending expanded parity rerun and tagged shell alias inspection. |
| `fork.no-pro-upsell` | cmux Mochi never offers an unpurchasable Pro upgrade and retains the explanatory fork row. | `09599eebd8`, `4bff2cbc38` | `ported` | Settings feature-flag and account-section behavior tests | Three Mochi bundle identities keep the explanatory account card but suppress upgrade actions; Welcome also states the no-Pro policy. |
| `ops.fork-release-overlay` | Fork identity, submodule ownership, universal build shape, build-number monotonicity, and Nightly/TestFlight lanes remain fork-owned and release-gated. | clean-trunk L0-L1 | `in-progress` | `scripts/fork-overlay-audit.sh`, `scripts/release-pretag-guard.sh`, and workflow contract tests | Pending final-SHA overlay, universal build, and pre-tag rerun; no external workflow dispatch before explicit approval. |
| `vscode.inline-workbench` | Inline VS Code serve-web and Claude browser-pane integration. | historical WIP | `retired` | Not applicable | Explicitly retired by product decision on 2026-08-26. |
<!-- parity-ledger:end -->

## Release rule

Parity completion requires all required rows above to be terminal, all named
focused selectors to execute non-zero tests, the test-target wiring lint and
unit build to pass, a tagged Debug app to build, and every candidate proof to be
recorded in `VALIDATION-MATRIX.md`. Device-only or human-visual evidence must be
named honestly; it cannot be replaced by source inspection.
