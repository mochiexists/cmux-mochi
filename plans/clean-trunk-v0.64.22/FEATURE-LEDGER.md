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
| `placement.adaptive-right` | A first beside-open from a full-width source creates a right split; later opens reuse the nearest aligned right pane across supported entry points. | `062e27b120` | `ported` | `WorkspaceRightSidePlacementPlannerTests` plus exact Markdown/file route selectors | Tagged topology proved Browser, Markdown, Artifact, and a temporary validated custom sidebar all reused the aligned right pane; file-preview and Markdown click routes passed in the app host. |
| `pane.zoom-persistence` | Bonsplit pane maximization survives save, quit, and relaunch using stable panel identity rather than regenerated pane identity. | `8293d1d059` | `ported` | `PaneZoomSessionPersistenceTests` | Tagged command-palette maximize stored the focused stable panel ID; normal quit/relaunch restored the same zoomed and focused panel with unchanged split topology. |
| `updater.opaque-popover` | The update-pill popover is opaque in light and dark appearance. | `bd4dcac9bf` | `ported` | `UpdatePillPopoverResizeTests` | AppKit host test proves an opaque dynamic `windowBackgroundColor`, which resolves for both appearances, and the tagged app exposes the update-pill debug journey. |
| `conductor.atomic-submit` | `cmux send --enter` and `--submit` atomically send literal text followed by Enter without shell reinterpretation. | `49f5d90983` | `ported` | `CMUXCLISendSubmitWaitTests` | Tagged CLI submitted a literal-separator fixture to the explicitly targeted surface without reinterpretation. |
| `conductor.agent-settle-wait` | `cmux send --wait` waits for the targeted agent to settle, with bounded timeout and correct unsupported/error behavior. | `815f3b5ab3` | `ported` | `CMUXCLISendSubmitWaitTests` | Tagged CLI returned only after the same targeted agent visibly acknowledged `CMUX_WAIT_ACK_CONFIRMED` and settled to Ready. |
| `sentry.startup-policy` | The fork starts Sentry only under its explicit channel/configuration policy and uses the fork project. | `3909e8ccd6` | `ported` | `MacSentryStartupPolicyTests` and `CMUXCLISentryTelemetryRegressionTests` | Built-bundle channel policy and fork DSN were checked; tagged Debug launched with the intended no-emission Debug policy. |
| `privacy.frost` | Workspace/group privacy controls persist, inherit correctly, redact the complete sidebar row, preserve menu access, and keep shipped teardown semantics. | `04bf56f8e5`, `f99cf9836e`, `26a2172ae8`, `c7a1d8d5ef` | `ported` | Focused workspace, sidebar-row, snapshot, observation, context-menu, and control-context privacy suites | App-host journey uses non-sensitive fixtures to toggle workspace/group privacy, restore it, render full-row frost, reject text leaks, preserve the menu action, and block private control routing. |
| `welcome.catalog` | `cmux welcome` lists only audited Mochi features that are present in this candidate. | `1c23ce721b` | `ported` | `CMUXCLIWelcomeRegressionTests` | Exact output from `CMUX_TAG=parity-recovery scripts/cmux-debug-cli.sh welcome` was audited against this ledger. |
| `task.resource-monitor` | An always-visible CPU/memory footer opens the reusable full-area Task Manager surface; its special selection is ephemeral and excluded from persistence. | `fa93267f31`, `6cf67ada07`, `5776fed431`, `3f64f17a05`, `1b5b758b2b`, `b267867d02`, `2ce5838b3b` | `ported` | `WorkspaceCoreValueTests`, Task Manager resource/surface/persistence suites | Tagged Window menu opened/reopened Task Manager; app-host proofs cover one reusable surface, process data, full-area portal hiding, always-visible resource summary, and zero Task Manager entries in the saved session. |
| `fork.no-pro-upsell` | cmux Mochi never offers an unpurchasable Pro upgrade and retains the explanatory fork row. | `09599eebd8`, `4bff2cbc38` | `ported` | Settings feature-flag and account-section behavior tests | Three Mochi bundle identities keep the explanatory account card but suppress upgrade actions; Welcome also states the no-Pro policy. |
| `vscode.inline-workbench` | Inline VS Code serve-web and Claude browser-pane integration. | historical WIP | `retired` | Not applicable | Explicitly retired by product decision on 2026-08-26. |
<!-- parity-ledger:end -->

## Release rule

Parity completion requires all required rows above to be terminal, all named
focused selectors to execute non-zero tests, the test-target wiring lint and
unit build to pass, a tagged Debug app to build, and every candidate proof to be
recorded in `VALIDATION-MATRIX.md`. Device-only or human-visual evidence must be
named honestly; it cannot be replaced by source inspection.
