# Mochi semantic replay feature ledger

This ledger is the behavior-level source of truth for replaying the released Mochi behavior from
`v0.64.173` onto upstream `v0.64.19`. Historical commit ownership is normalized separately in
[`SOURCE-COMMIT-MAP.tsv`](SOURCE-COMMIT-MAP.tsv); every one of its 196 rows must resolve to exactly
one feature ID below or to explicit historical churn.

## Frozen references

| Role | Ref | Commit |
| --- | --- | --- |
| Stable behavioral oracle | `v0.64.173` | `6cc68ba8ccfebcf9260e6fea049792b6cc44219b` |
| Untouched upstream source | `v0.64.19` | `1c22c556433fe035cdc60372bdd7443613f49a92` |
| Common ancestor | — | `d65cbf2e3757bfd0151b9f37d7f9b89760f6aaaa` |
| Historical stale baseline branch | `release/0.64.173-baseline` | `7a1c4b1bfbe6b9b704b8069e876c14aca450d481` |

The stale baseline branch is historical material only. It is not an oracle and must never satisfy a
stable-proof or topology check.

## Status vocabulary

- **Upstream state:** `equivalent`, `partial`, `absent`, `regressed`, `not-applicable`, or
  `pending: <named Phase 1 work>`.
- **Disposition:** `upstream-owned`, `port`, `retire`, or `defer: <blocker and re-evaluation trigger>`.
- **Welcome:** `shown`, `hidden: <reason>`, `status-only`, or `not-user-facing`.
- **Readiness:** `ready`, `blocked: <reason>`, or `deferred: <reason>`.

`pending:` and `blocked:` values are valid while preparation is being populated, but the final
readiness checker rejects them before semantic replay begins.

## Behavior inventory

<!-- replay-ledger:start -->
| ID | Behavior or invariant | Upstream state | Disposition | Stable proof | Future clean proof | Welcome | Evidence | Readiness |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `placement.adaptive-right` | First add beside a full-width source creates a 50/50 right split; later adds reuse the aligned right pane as tabs across all applicable entry points. | `partial` | `port` | Package planner tests plus live stable topology for Browser, Markdown, Artifact, and VS Code; file and custom-sidebar routes remain unrun. | Package planner tests and real tagged-app topology equality for every retained entry point. | `hidden: add after clean ownership` | `evidence/phase-1/live-browser-socket/summary.md`; `evidence/phase-1/adaptive-entrypoints/summary.md`; `evidence/phase-1/vscode-lifecycle/summary.md` | `blocked: owner clean placement replay; re-evaluate file and custom-sidebar routes on the tagged clean build and upstream comparison when its socket preflight survives` |
| `vscode.serve-web` | Open a directory in an inline VS Code serve-web workbench; reuse per workspace; stop and restart cleanly. | `partial` | `upstream-owned` | Stable same-directory reuse, isolated URL and profile ownership, process count, and post-exit leak are recorded. | Retain upstream behavior or add only a proven lifecycle delta with process cleanup tests. | `hidden: current Welcome omits it` | `evidence/phase-1/vscode-lifecycle/summary.md` | `blocked: owner inline VS Code lifecycle controller; re-evaluate stop, restart, multi-workspace ownership, and cleanup when the route is socket-accessible and upstream tagged preflight survives` |
| `vscode.extension-profile` | VS Code Server uses its own extension profile; users install, trust, and sign in normally without automatic marketplace mutation. | `partial` | `port` | Stable isolated profile root, process invocation, and shipped skill guidance are recorded without authentication. | Documentation validation plus live tagged-app proof that the server profile remains independent. | `hidden: candidate for later Welcome` | `evidence/phase-1/vscode-lifecycle/summary.md` | `blocked: owner authenticated VS Code profile fixture; re-evaluate install, trust, and sign-in only when a privacy-safe isolated credential fixture is explicitly available` |
| `task.resource-monitor` | Sidebar CPU and memory glance opens the full Task Manager or Resource Monitor. | `partial` | `upstream-owned` | Window → Task Manager opened the real manager; sidebar resource values and action were absent from Accessibility. | Upstream-equal shared action plus accessible sidebar values and real route proof. | `shown` | `evidence/phase-1/navigation-sidebar/summary.md` | `blocked: owner sidebar resource accessibility route; re-evaluate when the glance exposes values and an action to XCUITest or a bounded manual dogfood is explicitly available` |
| `navigation.reopen-closed` | Cmd+Shift+T restores closed tabs and workspaces in the correct order and state. | `partial` | `upstream-owned` | Eight ordering tests passed; live socket close did not enter UI history and keyboard/menu close routes were inert or disabled. | Shared-action tests and a real close/reopen journey with authoritative history mutation. | `shown` | `evidence/phase-1/browser-file/summary.md`; `evidence/phase-1/navigation-sidebar/summary.md` | `blocked: owner shared close and reopen action; re-evaluate when a tagged UI close increments recently-closed history and the keyboard route can restore it` |
| `navigation.sidebar-spring-load` | Cross-workspace drag spring-loads sidebar targets without losing drag state. | `partial` | `port` | The debug drag mutation completed but explicitly did not spring-load or commit; workspace rows were absent from Accessibility. | XCUITest or recorded manual drag proof against the tagged clean build. | `shown` | `evidence/phase-1/navigation-sidebar/summary.md` | `blocked: owner sidebar drag accessibility surface; re-evaluate when workspace rows expose drag targets or a bounded manual dogfood is explicitly available` |
| `files.backed-tab-actions` | Reveal in Finder, Copy File, and Copy Path work consistently across every file-backed panel. | `partial` | `upstream-owned` | Stable selector and source inventory cover the intended panels, but the app host emitted zero tests and no live route ran. | One shared file-backed action seam plus behavior coverage for every applicable panel. | `shown` | `evidence/phase-1/browser-file/summary.md` | `blocked: owner shared file-action path; re-evaluate when the stable selector emits non-zero tests and clipboard, Finder, and UI routes run` |
| `browser.external-routing` | One-click external-browser routing uses the expected target without disturbing cmux focus or state. | `partial` | `upstream-owned` | The tagged browser opened, but its external-routing control was absent from Accessibility; no external launch or focus claim is made. | Real tagged-app click/command proof or a small shared routing delta. | `shown` | `evidence/phase-1/navigation-sidebar/summary.md` | `blocked: owner browser routing accessibility surface; re-evaluate when the toolbar action is XCUITest-accessible or a bounded manual dogfood is explicitly available` |
| `agent.restore-no-autostart` | Restoring a native agent panel never launches a duplicate provider process. | `partial` | `port` | The isolated journey recorded that no authenticated provider was started; no PID-count claim is made. | Deterministic restore integration test and real process-count evidence. | `hidden: internal safety behavior` | `evidence/phase-1/capture-conductor/summary.md` | `blocked: owner authenticated agent restore fixture; re-evaluate only when a privacy-safe credential fixture is explicitly available` |
| `agent.resume-modes` | Medium, Full, and Off resume semantics, command prefill, first-turn behavior, and persistence remain correct. | `partial` | `port` | Sixteen launch tests passed; the app-host profile retained six fixture-dependent failures and no live per-mode relaunch ran. | Per-mode behavior tests and real relaunch proof for the locked semantics in `PRODUCT-SECURITY-DECISIONS.md`. | `shown` | `evidence/phase-1/agent-control/summary.md`; `PRODUCT-SECURITY-DECISIONS.md` | `blocked: owner session restoration harness; re-evaluate when all three modes complete a privacy-safe tagged relaunch` |
| `agent.scrollback-continuity` | Scrollback, cwd or resume binding, pane zoom, and crash or quit state survive restoration. | `partial` | `port` | Package and app-host overlap was captured; actual crash, kill, relaunch, and scrollback behavior remain unproved. | Session tests and real tagged-app restoration equality for retained behavior. | `shown` | `evidence/phase-1/agent-control/summary.md` | `blocked: owner session restoration harness; re-evaluate when crash, quit, scrollback, cwd, and zoom restore complete live` |
| `agent.lifecycle-events` | Agent state events are surface-attributed and round-trip through the event stream. | `partial` | `port` | All 23 codec cases passed and live delivery was redacted and surface-attributed; no provider lifecycle was started. | Upstreamable package event model plus live tagged-app provider lifecycle proof. | `shown` | `evidence/phase-1/agent-control/summary.md`; `evidence/phase-1/capture-conductor/summary.md` | `blocked: owner authenticated agent lifecycle fixture; re-evaluate ordering when a privacy-safe provider fixture is explicitly available` |
| `conductor.atomic-submit` | One operation types text and submits Enter with literal argument handling. | `absent` | `port` | Stable bundled CLI sent a literal 35-character shell fixture plus Enter; delivery and execution were observed without an agent acceptance claim. | Live agent-TUI integration test for text, Enter, literal separators, and failure paths. | `shown` | `evidence/phase-1/capture-conductor/summary.md` | `blocked: owner authenticated agent TUI fixture; re-evaluate provider acceptance only when a privacy-safe credential fixture is explicitly available` |
| `conductor.event-confirmed-submit` | Acceptance and completion are confirmed by surface-attributed lifecycle events rather than screen-stability polling. | `absent` | `port` | A redacted surface.input_sent delivery event was recorded; accepted-turn, completion, and polling behavior remain unproved. | Event-driven accepted-turn, completion, timeout, cancellation, unsupported-provider, and wrong-surface tests; no settle polling. | `hidden: current Welcome does not state the guarantee` | `evidence/phase-1/capture-conductor/summary.md`; `PRODUCT-SECURITY-DECISIONS.md` | `blocked: contract is locked; owner agent lifecycle adapters, re-evaluate live proof when a privacy-safe authenticated fixture emits accepted-turn events` |
| `conductor.live-job-guard` | Text injection is refused for a live non-agent foreground job while known agent TUIs and explicit override remain supported. | `partial` | `port` | Stable protocol and socket behavior for reject, exempt, force, and unavailable-state cases. | Shared socket-policy tests plus live tagged-app guard proof. | `shown` | `evidence/phase-1/agent-control/summary.md` | `blocked: owner socket send guard; re-evaluate when live reject, exempt, force, and unavailable routes execute` |
| `capture.workspace` | Workspace capture produces intended content and topology without leaking excluded UI. | `absent` | `port` | Stable live captures record lossless dimensions, digests, and sidebar include/exclude geometry; images were deleted and no private content is retained. | Built-app deterministic fixture capture and privacy-interaction tests. | `shown` | `evidence/phase-1/capture-conductor/summary.md` | `blocked: geometry and exclusion are recorded; owner clean capture replay, re-evaluate deterministic content against non-private fixtures on the tagged clean build` |
| `privacy.frost` | Sensitive workspaces or groups blur and redact correctly on screen and in capture workflows. | `absent` | `port` | No blurred state was active or automatable, so no stable visual or capture-redaction claim is made. | Real UI and capture tests with explicit non-private redaction fixtures. | `shown` | `evidence/phase-1/capture-conductor/summary.md` | `blocked: owner Privacy Frost state and accessibility route; re-evaluate when workspace or group frost can be set and captured with a privacy-safe fixture` |
| `diagnostics.show-copy-ids` | Show or copy workspace, pane, surface, agent-session, and resume identifiers. | `partial` | `upstream-owned` | Both identifier XCUITests launched and timed out before the first clipboard assertion; overlay and agent/resume IDs were not exercised. | Small diagnostics-domain tests plus real clipboard and overlay proof. | `shown` | `evidence/phase-1/identifiers/summary.md` | `blocked: owner macOS XCUITest event synthesis; re-evaluate when Cmd-Shift-P completes, then run overlay and agent/resume ID routes` |
| `sidebar.render-stability` | Busy agent workspaces avoid render storms and lazy-layout CPU loops. | `partial` | `upstream-owned` | A 21-workspace debug-drag datapoint records duration, CPU, and RSS without claiming a budget or busy-agent equivalence. | Retain upstream fixes; port only a reproducible regression with a fixed fixture and comparative budget. | `shown` | `evidence/phase-1/navigation-sidebar/summary.md` | `blocked: owner sidebar performance harness; re-evaluate when the fixed busy-agent fixture and surviving upstream tagged comparison can define a budget` |
| `socket.targeting-safety` | CLI and socket targeting, focus preservation, fallback, and errors are deterministic and safe. | `partial` | `upstream-owned` | Isolated Unix-socket fixtures plus real tagged-app CLI commands exposed a stable invalid-workspace success and topology mutation. | Invalid explicit targets fail nonzero without mutation; valid tagged targeting preserves focus and isolation. | `hidden: except Conductor wording` | `evidence/phase-1/agent-control/summary.md`; `evidence/phase-1/live-browser-socket/summary.md` | `blocked: defect and clean contract are recorded; owner socket target resolver, re-evaluate live upstream when tagged socket preflight survives` |
| `pane.zoom-persistence` | Pane zoom survives session persistence and relevant navigation. | `partial` | `port` | Stable source persists a panel ID for the zoomed pane; live relaunch remains grouped with session continuity. | Session tests and real tagged relaunch topology after the focused port. | `shown` | `evidence/phase-1/deferred-source-audit/`; `evidence/phase-1/agent-control/summary.md` | `blocked: owner pane-zoom replay; re-evaluate when a tagged save and relaunch restores the same pane zoom` |
| `updater.ui-fixes` | Updater popover remains opaque and feed behavior has no fork-feed leakage. | `partial` | `port` | Stable source adds opaque popover backgrounds; signed bundle, feed, and identity evidence are captured separately. | Built-bundle, visual popover, and update-feed proof after the fork overlay is reapplied. | `not-user-facing` | `evidence/phase-1/deferred-source-audit/`; `evidence/stable-v0.64.173/oracle-app-metadata.txt` | `blocked: source delta is audited; owner fork overlay, re-evaluate visual and feed proof on the signed clean nightly` |
| `artifacts.repository` | Artifact IDs, kinds, provenance, paths, revisions, and storage persist deterministically. | `absent` | `port` | Stable selectors and source identify the repository contract, but the app host emitted zero tests and no filesystem journey ran. | New CmuxArtifacts package with injected filesystem, clock, and process seams; actor serialization and package tests. | `shown` | `evidence/phase-1/artifacts-skills/summary.md` | `blocked: owner native Artifact repository replay; re-evaluate when deterministic stable or clean repository fixtures execute non-zero tests` |
| `artifacts.surface` | Create, open, focus, hot-reload, restore, and adaptively place a file-backed artifact pane. | `absent` | `port` | Stable live first and second opens record the 50/50 success and third-pane reuse defect; remaining lifecycle routes are source-correlated only. | Thin built-in panel and session adapters with real UI, restoration, renderer, and topology tests. | `shown` | `evidence/phase-1/adaptive-entrypoints/summary.md` | `blocked: stable topology defect is recorded; owner native Artifact replay, re-evaluate hot-reload, restore, and renderer routes on the tagged clean build` |
| `artifacts.renderer` | React, HTML, SVG, Mermaid, code, and file content render offline and recover from renderer-process failure. | `absent` | `port` | Two stable HTML opens recorded topology only; other kinds, reload, preview, recovery, relaunch, and navigation policy remain unproved. | CmuxArtifactsUI behavior tests enforce the default-deny offline policy in `PRODUCT-SECURITY-DECISIONS.md`. | `shown` | `evidence/phase-1/adaptive-entrypoints/summary.md`; `PRODUCT-SECURITY-DECISIONS.md` | `blocked: owner native Artifact renderer replay; re-evaluate when every kind, network denial, reload, preview, recovery, and relaunch route runs` |
| `artifacts.runtime-bridge` | Artifact content accesses an explicitly granted, scoped, and versioned cmux runtime API. | `absent` | `port` | Stable source records broad bridge methods and scope; the selected app host emitted zero tests and no live bridge request ran. | Per-artifact and per-surface grants, origin and source validation, bounded messages, revocation, and explicit denial tests. | `shown` | `evidence/phase-1/artifacts-skills/summary.md`; `PRODUCT-SECURITY-DECISIONS.md` | `blocked: owner native Artifact bridge replay; re-evaluate when grants, denials, bounds, revocation, and live requests execute` |
| `artifacts.storage-revisions` | Artifact-local persistence and bounded revisions behave safely under concurrent access and restore. | `absent` | `port` | Stable source and selectors identify storage and revision behavior, but the app host emitted zero tests and no filesystem journey ran. | Repository protocol tests for bounds, migration, serialization, and restore. | `shown` | `evidence/phase-1/artifacts-skills/summary.md` | `blocked: owner native Artifact repository replay; re-evaluate when revision, migration, bounds, serialization, and restore fixtures execute` |
| `artifacts.writers-room` | Writers' Room demonstrates intentional shared collaboration semantics. | `not-applicable` | `defer: define local, multi-process, or multi-user contract before replay; re-evaluate after artifact repository lands` | Historical commit `c476963ea1` is not an ancestor of either accepted baseline. | Opt-in authorization, canonical root, conflict model, bounded entries, and deterministic concurrent-writer tests. | `hidden: omitted from current Welcome` | `evidence/phase-1/deferred-source-audit/` | `deferred: owner future collaboration product contract; re-evaluate after native repository and authorization semantics are approved` |
| `skills.bundled` | cmux installs or ships modular skills for Codex and Claude without coupling the installer to individual skill content. | `absent` | `port` | Stable source and selectors identify installer behavior, but the app host emitted zero tests and no client-discovery journey ran. | Modular installer and per-skill validation with no global mutable runtime. | `hidden: current Welcome mentions Conductor only` | `evidence/phase-1/artifacts-skills/summary.md` | `blocked: owner modular skill installer replay; re-evaluate when isolated install, update, preservation, and client discovery execute` |
| `shell.yolo-aliases` | cxy and ccy aliases invoke clients with ambient unsafe mode in stable. | `absent` | `retire` | Stable shell definitions and resume builder behavior identify the unsafe ambient and fallback semantics. | No injected unsafe aliases or default-unsafe inference; historical metadata may be read and rendered as an explicit provider command. | `hidden: remove the stable Welcome claim` | `PRODUCT-SECURITY-DECISIONS.md`; `evidence/phase-1/agent-control/summary.md` | `blocked: owner shell replay; re-evaluate when fresh-shell absence and historical explicit-command compatibility tests pass` |
| `ovm.integration` | Stable Welcome points to OVM without a runtime dependency. | `absent` | `port` | Stable Welcome output and link provenance. | Optional documentation cross-reference only; no runtime coupling or top-level Welcome claim. | `hidden: retain in documentation, remove from clean Welcome` | `evidence/stable-v0.64.173/cmux-welcome.txt`; `PRODUCT-SECURITY-DECISIONS.md` | `blocked: owner OVM documentation replay; re-evaluate when clean docs retain the optional cross-reference and Welcome omits it` |
| `security.passkeys-status` | Developer ID builds report the temporary Passkeys or WebAuthn limitation accurately. | `not-applicable` | `port` | Installed signed stable CLI and affected runtime behavior. | Installed signed clean build proof until the underlying constraint changes. | `status-only` | `evidence/stable-v0.64.173/cmux-welcome.txt`; `evidence/stable-v0.64.173/oracle-app-metadata.txt` | `blocked: owner signed clean nightly; re-evaluate passkey status against the exact installed clean build` |
| `ops.fork-identity` | Mochi names, bundle IDs, URL schemes, Sentry, feeds, and repository targets are correct. | `not-applicable` | `port` | Stable source audit and installed bundle metadata. | Fork overlay source and built-bundle audit after product commits. | `not-user-facing` | `evidence/stable-v0.64.173/oracle-app-metadata.txt`; `evidence/*/manifest.json` | `ready: stable identity captured; overlay intentionally replays last` |
| `ops.release-lanes` | Stable and alpha or nightly remain separate signed and notarized apps and feeds; upstream-only lanes cannot mutate upstream infrastructure. | `not-applicable` | `port` | Stable and nightly workflow, release, tag, appcast, and installed-app evidence. | Exact-head branch and public nightly proof after overlay replay. | `not-user-facing` | `evidence/stable-v0.64.173/manifest.json`; `evidence/stable-v0.64.173/oracle-app-*.txt` | `ready: accepted lane URLs and signed stable oracle captured; repeat after overlay` |
| `ops.submodule-ownership` | Ghostty, bonsplit, and homebrew remotes and pointers are deliberate and reachable. | `not-applicable` | `port` | Stable tag submodule declarations, SHAs, remotes, and build evidence. | Retain only required fork patches with remote ancestry and parent-pointer proof. | `not-user-facing` | `evidence/*/manifest.json`; `evidence/*/logs/repository-setup.log` | `ready: all three declarations, SHAs, and successful builds captured` |
| `ci.release-build-shape` | The universal arm64 plus x86_64 single-file jobs-one Release build remains mandatory. | `partial` | `port` | Stable exact build command and release artifact architectures. | Upstream and clean exact-shape build logs and architecture inspection. | `not-user-facing` | `evidence/*/manifest.json`; `evidence/*/logs/universal-release-build.log` | `ready: stable, upstream, and prep-clean universal builds passed` |
| `welcome.catalog` | Stable Welcome claims remain traceable to ledger IDs and clean output does not overclaim. | `not-applicable` | `port` | Bundled stable CLI capture with every claim mapped below. | Derive human and machine-readable output from retained, clean-owned rows with completed behavior proof. | `not-user-facing` | `evidence/stable-v0.64.173/cmux-welcome.txt`; `PRODUCT-SECURITY-DECISIONS.md` | `blocked: owner Welcome catalog generator; re-evaluate after a clean human and machine-readable output contains only ready proven rows` |
| `future.erawan-room` | A future native Erawan-style moderated multi-agent room may reuse Artifact hosting, persistence, placement, workspace context, and supervised local-service seams. | `not-applicable` | `defer: separate future feature; re-evaluate after native Artifact packages and a second interactive consumer exist` | Accepted-baseline and source-map audit confirms it was not shipped. | No parity requirement. Preserve generic repository, host-bridge, workspace-grant, execution-service, placement, and state seams only. | `hidden: not shipped` | `evidence/phase-1/deferred-source-audit/` | `deferred: owner future multi-agent product design; re-evaluate after native Artifact packages and a second interactive consumer exist` |
| `future.native-agent-mirror` | Native external-session attach, transcript ingest, and screenshots requested on 2026-07-05 were not shipped in v0.64.173. | `not-applicable` | `defer: separate future feature; re-evaluate against upstream agent-chat architecture after replay` | Accepted-baseline and source-map audit confirms there is no released implementation. | No parity requirement. | `hidden: not shipped` | `evidence/phase-1/deferred-source-audit/` | `deferred: owner future agent-chat architecture; re-evaluate after replay against the current external-session model` |
| `history.release-churn` | Historical version bumps, changelog-only releases, conflict repairs, and obsolete CI fixes remain accounted for without replay. | `not-applicable` | `retire` | Complete source commit map and rationale. | No product proof; readiness checker verifies exact ownership and absence from the clean product stack. | `not-user-facing` | `SOURCE-COMMIT-MAP.tsv` | `ready` |
<!-- replay-ledger:end -->

## Source ownership status

The historical review now classifies all **196** non-merge commits exactly once across **33**
primary feature IDs. `history.release-churn` owns 36 explicit bookkeeping, integration, and CI rows;
those commits remain visible but are not replay candidates. The readiness checker verifies the exact
Git range, commit uniqueness, feature IDs, classifications, and reviewed rationales.

These ledger rows intentionally have no primary source-map commit:

- `artifacts.storage-revisions`: behavior was bundled inside the historical live-workbench commit,
  whose primary owner is `artifacts.renderer`; the clean replay separates it into a repository slice.
- `artifacts.writers-room`: the later historical implementation is not part of the accepted
  `v0.64.173` ancestry under review.
- `shell.yolo-aliases`, `ovm.integration`, and `security.passkeys-status`: shipped stable claims that
  predate or are not independently introduced by the measured overlay range; they still require
  behavioral or signed-artifact proof.
- `future.erawan-room` and `future.native-agent-mirror`: explicitly unshipped future work, tracked so
  it cannot be mistaken for replay parity.

## Stable Welcome claim mapping

The exact bundled CLI output is committed at
[`evidence/stable-v0.64.173/cmux-welcome.txt`](evidence/stable-v0.64.173/cmux-welcome.txt).
This mapping is the preparation contract; it does not modify stable Welcome.

<!-- replay-welcome:start -->
| Claim ID | Stable claim | Ledger IDs | Clean intent |
| --- | --- | --- | --- |
| `welcome.yolo` | Spawn agents fast through cxy and ccy aliases. | `shell.yolo-aliases` | Remove; unsafe aliases are retired. |
| `welcome.ovm` | Also see OVM. | `ovm.integration` | Remove from Welcome; retain only an optional documentation cross-reference. |
| `welcome.session-continuity` | Medium resume, scrollback, pane zoom, and crash or quit restore. | `agent.resume-modes`, `agent.scrollback-continuity`, `pane.zoom-persistence` | Rewrite from retained, independently proven sub-behaviors. |
| `welcome.resource-monitor` | Sidebar glance opens Resource Monitor or Task Manager. | `task.resource-monitor` | Retain only the demonstrated Mochi delta if upstream already owns the feature. |
| `welcome.conductor` | Visible Codex and Claude pane control. | `conductor.atomic-submit`, `agent.lifecycle-events`, `conductor.live-job-guard`, `capture.workspace`, `skills.bundled` | Rewrite to claim only clean-owned, event-proven behavior. |
| `welcome.artifacts` | Artifact panes and artifact CLI commands. | `artifacts.repository`, `artifacts.surface`, `artifacts.renderer`, `artifacts.runtime-bridge`, `artifacts.storage-revisions` | Retain after native modular implementation passes UI, storage, security, and restore proof. |
| `welcome.file-backed-tabs` | Reveal in Finder, Copy File, and Copy Path. | `files.backed-tab-actions` | Retain only for panel types that pass the shared behavior matrix. |
| `welcome.navigation` | Reopen closed tabs or workspaces and sidebar drag spring-load. | `navigation.reopen-closed`, `navigation.sidebar-spring-load` | Split or rewrite if upstream owns only part. |
| `welcome.privacy` | Privacy Frost blurs sensitive workspaces or groups. | `privacy.frost`, `capture.workspace` | Retain after screen and capture redaction proof. |
| `welcome.sidebar-stability` | Render-storm and lazy-layout fixes keep busy workspaces responsive. | `sidebar.render-stability` | Remove if upstream proves equivalent; do not claim internal fixes without performance evidence. |
| `welcome.browser-control` | Open in External Browser toggle. | `browser.external-routing` | Retain only if a clean-owned behavior remains. |
| `welcome.identifiers` | Copy or Show IDs and resume details. | `diagnostics.show-copy-ids` | Retain after clean diagnostics proof. |
| `welcome.passkeys` | Passkeys or WebAuthn are temporarily disabled. | `security.passkeys-status` | Keep only while verified true for the installed signed build. |
<!-- replay-welcome:end -->

## Shipped behavior currently omitted from Welcome

| Ledger ID | Current decision |
| --- | --- |
| `placement.adaptive-right` | Hidden today; add only after the clean placement behavior is owned and proven. |
| `vscode.serve-web` | Hidden today; add or omit deliberately after upstream-overlap proof. |
| `vscode.extension-profile` | Hidden today; candidate for concise guidance rather than a broad feature claim. |
| `agent.restore-no-autostart` | Internal safety behavior; keep hidden but prove it. |
| `conductor.event-confirmed-submit` | The current lifecycle wording does not prove submission confirmation; rewrite after event-driven completion exists. |
| `artifacts.writers-room` | Do not advertise; the collaboration contract is deferred. |
| `socket.targeting-safety` | Internal contract; document in CLI references rather than Welcome unless user value warrants it. |

## Stable changelog provenance

The stable release narrative is evidence, not a substitute for runtime proof. These are the primary
release-note anchors in `v0.64.173:CHANGELOG.md`:

| Ledger IDs | Stable release-note provenance |
| --- | --- |
| `placement.adaptive-right` | `0.64.173` Changed: first 50/50 right pane and later right-pane tab reuse. |
| `vscode.serve-web`, `vscode.extension-profile` | `0.64.173` Added and Changed: full workbench, one server per workspace, normal extension setup. |
| `conductor.atomic-submit`, `conductor.event-confirmed-submit` | `0.64.173` Changed and `0.64.153` Added: atomic text plus Enter, wait behavior, and claimed turn-start verification. |
| `agent.restore-no-autostart` | `0.64.173` Fixed: restored native agent tabs do not start a duplicate provider. |
| `files.backed-tab-actions` | `0.64.172` Added and `0.64.153` Changed: Copy File plus shared Reveal and Copy Path behavior. |
| `capture.workspace`, `skills.bundled`, `privacy.frost` | `0.64.171` Added or Changed and `0.64.169` Added: workspace capture, Claude skill install, and workspace or group Frost behavior. |
| `artifacts.repository`, `artifacts.surface`, `artifacts.renderer`, `artifacts.runtime-bridge`, `artifacts.storage-revisions` | `0.64.159` Added or Fixed: artifact panes, live bridge, file actions, renderer behavior, and workbench. |
| `diagnostics.show-copy-ids`, `skills.bundled` | `0.64.156` Added: identifier overlay and Mochi Conductor skill. |
| `task.resource-monitor` | `0.64.155` Fixed and `0.64.151` Added: bounded off-main matching, Task Manager, and sidebar resource readout. |
| `agent.resume-modes`, `agent.scrollback-continuity` | `0.64.151` Added or Fixed plus later hotfix notes: tri-state resume, pre-typed Medium mode, and captured scrollback. |
| `navigation.sidebar-spring-load`, `navigation.reopen-closed`, `browser.external-routing`, `files.backed-tab-actions` | `0.64.151` Added: the original Mochi navigation, browser, and path-action set. |
| `security.passkeys-status`, `welcome.catalog` | `0.64.161` Added and `0.64.166` Changed: Developer ID limitation note and Welcome ordering. |
| `ops.release-lanes`, `ci.release-build-shape`, `ops.submodule-ownership` | `0.64.160` through `0.64.169` release notes: signing, universal build memory, GhosttyKit provenance, and runner hardening. |

## Artifact and future Erawan architecture boundary

Artifacts should be replayed as a native upstreamable feature, not as the current app-global store and
not as a new pane-extension platform in this critical path:

1. `CmuxArtifacts` owns pure IDs, records, repository protocols, an injected filesystem repository
   actor, revisions or storage, and scoped change streams.
2. `CmuxArtifactsUI` owns renderer lifecycle and a least-privilege, versioned host-capability
   protocol.
3. The app target owns only thin panel, session, placement, socket, and CLI composition adapters.
4. Generic seams prepared now include document identity, workspace grants, supervised helper
   lifecycle, placement request or result, bounded structured state, and transport-neutral host
   capabilities.
5. Erawan participant routing, model drivers, unsafe permission modes, arbitrary browser-supplied
   folders, public HTTP control, and public or private pane ExtensionKit hosting remain separate
   future product decisions.
