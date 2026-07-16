# Clean upstream refresh and Mochi feature replay

## Objective

Build the next cmux Mochi line from a fresh upstream release-tag worktree, then replay the
Mochi product behavior as a small, reviewable, upstream-friendly commit stack. Do not rebase
the existing 200-commit fork history wholesale.

The migration is complete only when:

- every behavior shipped in `v0.64.173` has an explicit disposition: **upstream owns it**,
  **ported**, **intentionally retired**, or **deferred with a named blocker**;
- every retained feature is green in the commit that introduces it;
- a clean-fork nightly is signed, notarized, and installed beside stable `v0.64.173`;
- the stable-versus-nightly regression matrix passes;
- fork identity, signing, update feeds, release lanes, and submodule ownership survive the
  refresh audit.

This plan prepares and validates the clean stack. It does not open upstream PRs or issues,
force-push shared branches, or publish a new stable release without a separate release decision.

## Frozen references and live divergence

Record these refs in the migration ledger before starting. If upstream publishes a newer stable
tag before implementation begins, repeat the inventory and deliberately update the baseline;
never silently switch to `upstream/main`.

| Role | Ref | Commit |
| --- | --- | --- |
| Current stable behavior baseline | `v0.64.173` | `6cc68ba8ccfebcf9260e6fea049792b6cc44219b` |
| Fresh upstream source baseline | `v0.64.19` | `1c22c556433fe035cdc60372bdd7443613f49a92` |
| Observed upstream tip, not the base | `upstream/main` | `2dc5237c59e06b8f1007533cd4d14b13e702e553` |
| Common ancestor | — | `d65cbf2e3757bfd0151b9f37d7f9b89760f6aaaa` |

Live inventory on 2026-07-15:

- fork commits since the common ancestor: 200 (196 non-merge);
- upstream `v0.64.19` commits since the common ancestor: 1,132 (985 non-merge);
- historical fork overlay from the common ancestor: 358 files, +27,772/-5,496;
- exact patch-equivalent fork commits found by `git cherry v0.64.19 v0.64.173`: zero.

Those numbers make a history rebase the high-risk option. The chosen strategy is a fresh branch
from the release tag plus semantic feature replay.

## Working layout

Preparation uses three persistent worktrees outside `/tmp`, while this historical planning checkout
remains available for source archaeology:

```bash
cd /Users/timapple/Documents/mochi/mochi-dev/cmux-inline-vscode-clean

git worktree add --detach \
  /Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v064173-oracle \
  v0.64.173

git worktree add --detach \
  /Users/timapple/Documents/mochi/mochi-dev/cmux-upstream-v06419-baseline \
  v0.64.19

git worktree add \
  -b refactor/mochi-v0.64.19-clean \
  /Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06419-clean \
  v0.64.19

for worktree in \
  /Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v064173-oracle \
  /Users/timapple/Documents/mochi/mochi-dev/cmux-upstream-v06419-baseline \
  /Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06419-clean; do
  git -C "$worktree" submodule update --init --recursive
done
```

Keep these roles distinct throughout the migration:

- detached `v0.64.173` at `6cc68ba8…`: immutable behavioral oracle and source-test baseline;
- installed signed `v0.64.173`: release-artifact and A/B oracle;
- detached `v0.64.19` at `1c22c556…`: untouched upstream behavior baseline;
- `refactor/mochi-v0.64.19-clean`: preparation and clean semantic replay stack;
- `main`: released Mochi trunk, updated only after the clean stack is accepted.

The local `release/0.64.173-baseline` branch is stale historical material at `7a1c4b1b…`; never use
it as the stable oracle. Give every role a distinct app tag, DerivedData root, scratch root, fixture
root, Unix socket, `HOME`, and `CFFIXED_USER_HOME`.

## Rules for the clean stack

1. One green, independently reviewable behavior per commit. Do not replay version bumps,
   changelog-only releases, conflict-resolution commits, or old CI repairs that the new base no
   longer needs.
2. Prefer reimplementation against current upstream APIs. Use `git cherry-pick -n` only when a
   commit is already self-contained, still architecturally correct, and its full diff is wanted.
3. Keep upstream hot files as adapters. New behavior belongs in an existing cohesive package or
   a justified domain package; `Workspace`, `ContentView`, `AppDelegate`, `TabManager`, and
   `TerminalController` should normally receive only composition or forwarding changes.
4. Packages remain a downward-only DAG: Core values/protocols -> service actors/repositories ->
   `@MainActor @Observable` domain/coordinators -> UI -> executable composition root.
5. No new runtime singleton, global mutable store, screen-stability polling, or sleep-to-settle
   synchronization. Inject services at the app composition root and expose real async signals.
6. Every public package API gets DocC and package-local tests. Every app-target test file must be
   wired into both the project and the test target and must execute a non-zero test count.
7. All user-visible strings go through the localization catalog with English and Japanese entries.
8. Run `scripts/normalize-pbxproj.py` and `scripts/check-pbxproj.sh` after project wiring changes.
9. Run `git submodule update --init --recursive` after every branch switch and verify fork-owned
   submodule URLs only after the fork overlay is applied.
10. Never move or reuse a failed stable tag. The clean nightly is the promotion gate; versioning
    happens after the stack is accepted.

## Required migration inventory

Create these artifacts in the clean worktree before the first feature commit:

- `SOURCE-COMMIT-MAP.tsv`: one normalized row for every historical non-merge commit;
- `FEATURE-LEDGER.md`: one row per behavior or release invariant;
- `VALIDATION-MATRIX.md`: stable, upstream, and future-clean proof recipes and evidence;
- `evidence/*/manifest.json`: structured baseline environment, command, artifact, and failure records.

Every feature row has a stable ID and records behavior, source ownership, stable proof, upstream
state, disposition, future clean proof, Welcome disposition, evidence, and readiness or blocker.
Every source-map row records the full SHA, date, subject, owning feature ID, classification, and
rationale. Valid classifications are behavior, release-version-churn, test-support, docs-support,
upstream-backport, and obsolete-infrastructure.

Populate the inventory from all 196 non-merge commits, then collapse release churn into behavior
rows while retaining one-to-one source ownership:

```bash
BASE=$(git merge-base v0.64.173 v0.64.19)
git log --no-merges --reverse --format='%H%x09%ad%x09%s' --date=short \
  "$BASE"..v0.64.173
git diff --name-status "$BASE"..v0.64.173
git log --no-merges --format='%H%x09%s' "$BASE"..v0.64.173 -- <feature-path>
```

No source commit may disappear, appear twice, or point at an unknown feature ID. Cross-cutting
commits receive one primary owner and may list related IDs in their rationale. Release/version,
test, documentation, upstream-backport, and obsolete-infrastructure commits remain explicit rows;
they are classified rather than replayed. The readiness checker enforces this ownership before
semantic replay begins.

## Initial feature disposition

This is the starting hypothesis from the live `v0.64.19` audit. Phase 1 must prove each row and
may change the disposition with evidence.

| Feature family | Initial disposition | Reason / proof target |
| --- | --- | --- |
| Upstream sidebar performance backports (`#6807`, `#7117`, `#7221`) | Upstream-owned | Present in the newer upstream history; do not replay fork backports. |
| Task Manager and reopen-closed-item infrastructure | Upstream-owned | Both are present in `v0.64.19`; compare UX and retain only missing Mochi deltas. |
| Core inline VS Code `serve-web` workbench | Upstream-owned first | `v0.64.19` already discovers VS Code, runs `serve-web`, and opens it in a native browser surface. Prove folder routing and lifecycle before adding runtime code. |
| VS Code skill and extension-profile explanation | Port | Keep the concise user guidance: VS Code Server has an independent extension profile; users install/trust/sign in normally. Do not auto-install marketplace extensions. |
| Adaptive “open beside me” placement | Port | Missing upstream. First request from a full-width pane makes a 50/50 right split; later requests reuse the existing right pane as tabs. |
| Restored native agent-session provider autostart suppression | Port | Upstream still starts auto-start providers without a restored-session distinction. |
| Atomic conductor submission and confirmation | Port, redesign wait | Upstream `send` still only types. Port explicit type+Enter semantics; replace screen-settle polling with lifecycle/event confirmation. |
| Agent lifecycle events and surface attribution | Port after overlap audit | Needed for deterministic conductor completion and useful independently of the skill. |
| Refuse text injection into a live non-agent foreground job | Port if upstream lacks equivalent guard | Preserve safety without blocking known agent TUIs. |
| Artifact workbench, `artifact.new`, live bridge, Writers' Room sample | Port | No equivalent macOS artifact pane exists in `v0.64.19`. Rebuild around injected repository/service boundaries. |
| Bundled cmux skills for Codex and Claude | Port | Fork product capability; keep runtime installer separate from individual skill content. |
| Workspace capture and Privacy Frost | Evaluate then port missing behavior | Upstream has changed workspace/canvas architecture; preserve capture semantics and privacy without replaying old view diffs. |
| Agent resume modes, alias prefill, and scrollback continuity | Evaluate carefully | Upstream now has significant session tracking and restore work but not the Mochi tri-state `medium` policy. Re-prove each behavior independently. |
| Show/Copy IDs overlay | Evaluate/port | Symbol absent in `v0.64.19`; redesign as a small diagnostic domain rather than restoring large `ContentView` hunks. |
| Sidebar spring-load during cross-workspace drag | Evaluate | Re-run the stable recipe against current upstream; port only if the behavior is still absent. |
| Tab path actions and external-browser launch target | Evaluate | Upstream UI has evolved; compare user behavior before retaining fork code. |
| Socket fallback, pane zoom persistence, updater UI fixes | Evaluate for upstream equivalence | These are likely partly or fully superseded. Keep only a demonstrated regression. |
| Bonsplit/Ghostty fork pins | Minimize | Prefer upstream submodule commits. Retain a fork pointer only for a still-required patch with its own proof and upstream submission candidate. |
| Mochi identity, signing, feeds, release lanes, Sentry, dead-lane guards | Port last as fork overlay | Operationally required but intentionally not upstreamable. Keep separate from product commits. |

The 2026-07-05 agent-surface request also gets explicit rows. Native external-session attach,
agent-surface transcript ingest, and agent-surface screenshots were not completed by the current
fork. Do not claim them as regressions. The clean stack should retain the reliable terminal/TUI
conductor path and lifecycle events; native read-only mirroring remains a separate feature unless
the new upstream agent-chat architecture makes it small and supportable.

## Phase 0 — Establish three clean baselines

Before changing product code:

1. Create and verify the detached stable oracle, detached untouched upstream, and clean branch
   worktrees described above. Record exact HEADs, declared submodule URLs, checked-out submodule
   SHAs, and clean status before and after every baseline run.
2. Record exact stable CI, nightly, stable workflow, and release URLs in the stable evidence
   manifest. Inspect the installed signed app separately from the stable source build.
3. Build and test stable source, untouched upstream, and the preparation-only clean branch with
   role-specific DerivedData, scratch, fixture, socket, app-tag, and home paths.
4. Launch explicitly tagged development builds without replacing either installed Mochi
   application or sharing runtime state across roles.
5. Capture every baseline failure with scope, reproduction, owner, and blocker. Do not “fix” a
   baseline failure inside a feature commit.
6. Run the semantic replay readiness checker in artifact and local-topology modes. Keep CI
   enforcement disabled until all required evidence is populated.

Baseline commands:

```bash
swift test --package-path Packages/macOS/CmuxWorkspaces
swift test --package-path Packages/macOS/CmuxControlSocket
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-v06419-baseline build
CMUX_SKIP_ZIG_BUILD=1 xcodebuild -project cmux.xcodeproj -scheme cmux \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/cmux-v06419-release -jobs 1 \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  SWIFT_COMPILATION_MODE=singlefile CODE_SIGNING_ALLOWED=NO build
```

Use the repo's current test scripts where they supersede these raw commands. The exact universal
single-file Release build remains mandatory because it catches failures that Debug does not.

Gate: untouched upstream builds, package tests have a recorded result, and the baseline failure
list is committed to the ledger before the first port.

## Phase 1 — Prove upstream overlap before writing code

For each ledger row:

1. Run the stable `v0.64.173` proof recipe.
2. Run the same recipe on the tagged `v0.64.19` dev build.
3. Inspect current upstream source and tests.
4. Mark the behavior equivalent, partial, absent, or intentionally changed.
5. Choose a disposition and acceptance test.

Start with the likely supersessions: VS Code workbench, Task Manager, reopen closed items,
sidebar performance, socket routing, tab path actions, and browser launch behavior. Dropping code
is a positive outcome when upstream passes the same behavior test.

Gate: every source commit is accounted for, every port row has a concrete acceptance test, and
there are no “keep just in case” entries.

## Phase 2 — Shared adaptive right-side placement

Port this first because it is cohesive, package-testable, and a dependency of artifacts, VS Code,
browser/file previews, Markdown, and custom sidebars.

Target shape:

- pure `WorkspaceRightSidePlacementPlanner` value in `CmuxWorkspaces`;
- immutable Bonsplit tree snapshot input;
- outcomes: reuse existing right pane as a tab, reuse the source when already at the right edge,
  or create one right split;
- tiny app-target adapter resolving `PaneID` and invoking existing creation APIs;
- every “beside” entry point calls the same adapter.

Clean commits:

1. `feat(workspaces): add adaptive right-side placement policy`
   - package values, planner, DocC, package tests only;
   - cases: full width, left/right pair, right-edge source, vertical stack, 2x2 alignment,
     headless geometry, missing source.
2. `feat(workspaces): route beside openings through shared placement`
   - browser, Markdown, file preview, artifact, inline VS Code, and custom-sidebar adapters;
   - app tests prove no nested 25/25 split after a right pane already exists.

Gate: `CmuxWorkspaces` tests, focused app tests, Debug build, and one visual topology smoke.

## Phase 3 — Deterministic conductor I/O

Build the protocol/runtime capability before changing skill prose.

Target behavior:

- `cmux send --enter` / `--submit` types and submits as one requested operation;
- command output identifies the resolved target and whether Enter was delivered;
- a caller can wait on an agent lifecycle transition attributed to the same surface/turn;
- failure/timeout is explicit and non-zero;
- sending to an unrelated live foreground process is rejected unless the caller deliberately
  overrides it;
- the conductor skill reads back enough state to prove that the prompt left the input and the
  agent entered working/finished state.

Do not retain the current screen-unchanged polling loop as the final completion primitive. Use
the agent event stream or an `AsyncStream` exposed by the responsible service. A bounded timeout
is allowed; sleep-to-settle polling is not.

Clean commits:

1. `feat(events): publish attributed agent lifecycle transitions`
2. `feat(control): guard text delivery by foreground process ownership`
3. `feat(cli): add explicit submit and lifecycle wait to send`
4. `docs(skills): verify conductor prompt submission`

Tests cover literal `--enter` after `--`, submit aliases, target resolution, Enter-delivery
failure, non-agent rejection, agent allowance, event attribution, completion, and timeout.

Gate: `CmuxControlSocket` tests, CLI integration tests against a tagged dev app, conductor skill
validation, and a live Codex-to-Claude/Codex turn where the receiving pane visibly submits.

## Phase 4 — Native agent-session restore safety

Port only the restored-panel distinction, not old agent-session renderer code.

Target shape:

- restoration passes a value describing launch intent (`restoredDormant` versus `newInteractive`),
  rather than a loose Boolean if current upstream APIs make that natural;
- provider metadata reports auto-start capability separately from whether this panel should
  auto-start now;
- restored panels render without spawning a second provider process;
- explicit user resume/start still launches exactly once.

Clean commit: `fix(agent-session): keep restored provider panels dormant until resumed`.

Gate: provider policy unit tests, session-restore tests, process-count smoke, and a relaunch test
covering both Codex and a provider that normally auto-starts.

## Phase 5 — Inline VS Code, upstream first

Run the minimal acceptance test against untouched `v0.64.19`:

1. Discover Visual Studio Code or explain how to install it.
2. Open a selected directory through `code-tunnel serve-web` in a native cmux browser pane.
3. Open a second directory/workspace without killing the first active workbench unexpectedly.
4. Stop/restart the server and close its owning workspace without leaking a process or token file.
5. Confirm the web workbench uses its own extension profile; manually install/trust the Anthropic
   extension and sign in through normal VS Code UI.

If upstream passes, add only the bundled skill:

- `docs(skills): add inline VS Code workbench workflow`.

If a real lifecycle gap remains, replace the current singleton workspace registry with an injected
`VSCodeServeWebService` actor (in a cohesive service package if the test seam justifies it). The app
composition root owns it; workspace close calls the service; tests use injected process launching,
filesystem, token paths, and clock/deadline. Then use two commits:

1. `fix(vscode): scope serve-web lifecycle to workspace ownership`
2. `docs(skills): add inline VS Code workbench workflow`

Never auto-install or silently trust marketplace extensions. The skill explains that desktop VS
Code extensions and the server profile are separate and that install/trust/sign-in is a one-time
normal UI action in the server workbench.

Gate: focused lifecycle tests, no orphan process/token files, native pane visual smoke, and skill
validation.

## Phase 6 — Native upstreamable Artifact domain

Rebuild artifacts as a native domain rather than restoring the current app-target global store or
introducing a pane-extension platform on the replay critical path.

Package and composition shape:

- `CmuxArtifacts`: Sendable artifact and document identities, records, entries, validation,
  repository protocols, an injected filesystem repository actor, bounded reads, revision or
  storage policy, and scoped `AsyncStream` change observation;
- `CmuxArtifactsUI`: WebKit or SwiftUI renderer lifecycle plus a versioned, transport-neutral,
  least-privilege host-capability protocol; never depend directly on `Workspace`, `AppDelegate`, or
  a concrete repository;
- executable target: composition and minimal panel, session, placement, workspace, socket, and CLI
  adapters;
- one placement request/result use case shared by UI, CLI, socket, and future interactive surfaces;
- explicit separation between renderer lifecycle and any helper or local-process lifecycle.

Prepare generic seams that are useful both upstream and to a later Erawan-style native room:

- logical document identity independent of filesystem path;
- workspace-context resolution through canonical, user-approved roots;
- supervised execution-service protocol for launch, readiness, events, stop, restart, and logs,
  without embedding model-provider or Erawan policy;
- structured bounded artifact-local state and opaque external session references;
- capability-scoped snapshots, events, storage, surface reads, and typed actions;
- generic session restoration for native file-backed and interactive surfaces.

Clean commits:

1. `feat(artifacts): add artifact domain and repository`
2. `feat(artifacts): add native artifact panel and restoration`
3. `feat(artifacts): add renderer and scoped host capabilities`
4. `feat(artifacts): add artifact creation control and CLI`
5. `docs(skills): add artifact creation recipes`

Security/correctness invariants:

- no global store or runtime singleton;
- paths are canonicalized beneath an explicitly selected root;
- entries and bridge messages are schema-validated and size-bounded;
- concurrent writes do not corrupt the repository;
- renderer recovery does not freeze the app;
- placement responses describe the pane or tab actually created;
- host capabilities are explicit, auditable, and least-privilege;
- artifact session restoration handles missing or moved content without crashing.

Defer Writers' Room collaboration semantics, Erawan participant routing and model drivers, unsafe
permission modes, arbitrary browser-supplied directories, public HTTP control, and public or private
pane ExtensionKit hosting. Reconsider an out-of-process pane host only after at least two materially
different native consumers cannot share these prepared runtime contracts.

Gate: package tests, repository concurrency and migration tests, bridge and renderer security tests,
CLI tests, right-placement integration, session restore, and real tagged-app artifact UI smoke.

## Phase 7 — Remaining Mochi product slices

Work strictly from the ledger, one vertical slice at a time. Recommended order minimizes shared
hot-file churn:

1. bundled skill installer (Codex and Claude destinations, idempotent updates);
2. workspace capture, sidebar exclusion, and Privacy Frost;
3. agent resume tri-state, alias prefill, and scrollback continuity;
4. Show/Copy IDs diagnostic overlay;
5. sidebar drag spring-load if still missing;
6. any proven missing tab-path/browser/updater/socket/zoom behavior;
7. submodule-only patches that remain necessary.

Each slice must have:

- stable proof and upstream failure recorded first;
- a named domain owner and dependency direction;
- one green implementation commit (or a small ordered stack when the domain genuinely requires it);
- focused tests plus Debug compile;
- no unrelated formatting, version, changelog, or release changes.

If a slice requires more than three-line hooks in several upstream hot files, stop and design a
Coordinator/Service/Repository seam before editing. Do not recreate the current large
`ContentView.swift`, `Workspace.swift`, or `AppDelegate.swift` overlay.

## Phase 8 — Apply the fork overlay last

Only after the product stack is green, apply the intentionally non-upstreamable fork machinery.

Clean commits:

1. `chore(fork): apply Mochi identity and owned submodules`
   - app/bundle names and URL schemes;
   - entitlements and signing-team compatibility;
   - stable/nightly socket variants;
   - only still-required Ghostty/Bonsplit fork URLs and pins.
2. `ci(fork): restore Mochi release and update lanes`
   - exact universal build script;
   - stable and separate-app nightly identities/feeds;
   - signing, notarization, Sparkle, Sentry, daemon assets;
   - repo-variable runner routing;
   - guards on upstream-only workflows;
   - pre-tag guard and immutable-asset checks.
3. `docs(fork): document overlay audit and release operations`
   - `FORK.md`, release skill/checklist, current gotchas.

Extend `scripts/fork-overlay-audit.sh` to verify at least:

- no upstream signing team, feed, app name, or release repository leaks into shipping paths;
- Mochi bundle IDs, feed URLs, app names, and Sentry target are present;
- identity injection runs before code signing;
- stable and nightly remain separate bundles and feeds;
- submodule URLs and pointers are deliberate;
- upstream-only workflows cannot mutate Manaflow infrastructure from the fork;
- release workflows call the same universal build script proven by CI.

Do not bump the final version in these commits. Version/changelog prep is a separate release commit
after the clean nightly is accepted.

## Per-commit validation gate

Every commit must pass the smallest complete gate for its scope:

- changed Swift package: `swift test --package-path <package>`;
- app-target Swift: focused non-zero test suite and Debug build;
- project file: normalization and project check scripts;
- workflow: `actionlint` plus the matching shell guard tests;
- localization: localization audit with en/ja coverage;
- skill: skill validation and bundle/install test;
- submodule: build/test inside the submodule plus parent pointer validation.

At the end of every phase:

```bash
git status --short
git diff --check v0.64.19..HEAD
```

Before Phase 8, compare fork-sensitive paths against the ledger because the new branch does not
yet contain the fork audit script. From Phase 8 onward, also run:

```bash
./scripts/fork-overlay-audit.sh
```

At product-stack milestones, run the exact universal Release build. Before any nightly, require a
successful full `ci.yml` run on the exact candidate SHA.

## Clean-history review gate

Before moving the stack toward `main`:

```bash
BASE=$(git merge-base v0.64.173 v0.64.19)
git log --reverse --oneline v0.64.19..HEAD
git range-diff "$BASE"..v0.64.173 v0.64.19..HEAD
git diff --check v0.64.19..HEAD
git diff --stat v0.64.19..HEAD
```

Review every commit independently:

- does it build and test at that point in history?
- does its message name the behavior rather than the migration?
- could an upstream maintainer review it without understanding Mochi branding?
- are fork-only values absent from upstreamable commits?
- is there a smaller current-upstream API that eliminates the patch?

Prepare upstream contribution branches only after this review, one feature per branch from the
same upstream tag (or current upstream main after rebasing that individual contribution). Do not
push or open upstream PRs without explicit approval.

## Nightly and stable-versus-clean regression

1. Run a branch nightly on the clean candidate first. It may upload an Actions artifact but must
   not move the public rolling nightly tag.
2. Verify the branch artifact's version, architectures, signature/notarization, bundle ID, feed,
   daemon manifest, and appcast.
3. After exact-SHA CI and review, integrate the clean stack into `main` using a strategy that
   preserves the curated commits.
4. Dispatch the public rolling nightly from exact `main` HEAD and verify tag, release assets, and
   appcast independently.
5. Install stable `v0.64.173` and the clean nightly side by side. Use separate config/socket
   identities and the same fixture repository.

Required A/B matrix:

| Area | Stable `v0.64.173` | Clean nightly |
| --- | --- | --- |
| Launch, update feed, bundle identity, CLI discovery | Baseline | Equal or deliberately changed |
| One full-width pane -> add right | 50/50 | 50/50 |
| Existing right pane -> add right again | New tab in right pane | Same |
| Browser, Markdown, file, custom sidebar, VS Code, artifact placement | Baseline | Same topology |
| Inline VS Code directory open, stop/restart, extension profile | Baseline | Same or upstream-better |
| Restored native agent panel | No duplicate provider | Same |
| Conductor prompt submit | Prompt leaves input and turn starts | Same, with event proof |
| Artifact create/render/live update/Writers' Room | Baseline | Same |
| Resume mode and scrollback after relaunch | Baseline | Same for every retained mode |
| Privacy/capture behavior | Baseline | Same |
| CLI/socket targeting and safety errors | Baseline | Same or stricter documented result |
| Core upstream workflows not modified by Mochi | — | `v0.64.19` behavior preserved |

Record screenshots/topology JSON, process counts, CLI output, test logs, and app metadata in
`plans/fork-overlay-cleanup/VALIDATION-MATRIX.md`. “Looks good” is not a passing row.

## Promotion and rollback

Promote only when:

- the feature ledger has no unowned source commit;
- exact candidate SHA is fully green in CI;
- the public clean nightly is signed, notarized, and verified;
- all required A/B rows pass or have an approved intentional delta;
- the fork overlay audit passes against both source and built bundles;
- the curated commit stack has been reviewed for upstreamability.

Keep `v0.64.173` installed and immutable throughout testing. If the clean nightly regresses, move
the nightly only through the normal workflow after fixing the branch; do not change stable. If a
stable tag is eventually cut and its workflow fails, fix forward with the next patch version—never
move or reuse the failed tag.

## Completion report

The final implementation report must include:

- upstream and stable SHAs used;
- feature ledger counts by disposition;
- ordered clean commit list;
- package/dependency changes;
- every test/build/workflow run and exact result;
- branch and public nightly run IDs plus verified assets/appcasts;
- stable-versus-clean regression matrix;
- retained fork-only diffs and why each cannot be upstreamed;
- prepared upstream contribution branches, if any, without publishing them;
- remaining blockers or intentionally deferred features.
