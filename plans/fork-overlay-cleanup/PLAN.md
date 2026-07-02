# Fork overlay cleanup — make cmux-mochi a thin toggle on upstream

**Goal:** shrink the fork's diff against upstream (`manaflow-ai/cmux`) so rebases stop being
release-breaking events, convert the nightly lane into a dispatch-only ALPHA lane, and make the
release pipeline provably identical between CI and the release workflow.

**Executor:** Codex (multi-turn). **Reviewer:** Claude reviews each phase's outcome before the
next phase starts. **Do not** create tags, publish releases, dispatch workflows on GitHub, or
open PRs/issues on any repo as part of this plan — all of that is done by Phil manually.

---

## Context you need before touching anything

- Repo: `/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-clean`. Trunk is `main`.
  `origin` = `mochiexists/cmux-mochi` (fork), `upstream` = `manaflow-ai/cmux`.
- Upstream base: `git merge-base main upstream/main` = `d65cbf2e3` (2026-06-23, ≈ upstream
  v0.64.17, their latest release). Fork carries 117 commits: 44 added files, 217 modified
  upstream files, +20.6k/−4.5k.
- Current shipped fork release: v0.64.166 (build 111). Stable feed:
  `https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml`.
- Fork identity values (canonical, from fork-overlay memory): Team ID `599WAZ6282`,
  stable bundle `com.cmux-mochi`, app name `cmux Mochi`, nightly bundle
  `com.cmux-mochi.nightly` / name `cmux Mochi NIGHTLY` (becomes ALPHA in Phase 4).
- **Work on a branch per phase** off `main` (`fix/overlay-p0-guards`, `refactor/overlay-p1-build`,
  …). One logical change per commit, conventional messages. Merge to `main` only after the
  phase's verification gate passes and Claude has reviewed.

### Hard rules (violating any of these = stop and report)

1. **Never run bare `xcodebuild` into the default derived-data path and never launch an
   untagged `cmux DEV.app`.** For Debug builds use `./scripts/reload.sh --tag overlay-p<N>`
   (build only, no `--launch`). For compile-only checks use
   `-derivedDataPath /tmp/cmux-overlay-p<N>`.
2. **After any branch switch: `git submodule update --init`** (ghostty and vendor/bonsplit
   pointers do not auto-update).
3. **pbxproj:** the pre-commit hook normalizes `cmux.xcodeproj/project.pbxproj`. If you add a
   test file under `cmuxTests/`, it MUST be wired into the pbxproj (four entries; copy the
   pattern from `TabManagerUnitTests.swift`) — otherwise it silently never runs
   ("Executed 0 tests" is a failure, check for it explicitly).
4. **Baseline test failures exist.** Before claiming your change broke or fixed anything in the
   broad suites, run the same suite on `main` at the same base and diff the failure lists. Only
   NEW failures are yours. Do not chase pre-existing failures; list them in your report.
5. **All user-facing strings localized** (`String(localized:)` + entries in
   `Resources/Localizable.xcstrings` for en AND ja). Phase 4 touches user-visible text.
6. Shell is zsh on macOS; `python3` not `python`; bash 3.2 has no associative arrays.
7. Do not modify anything under `web/services`, `workers/`, or Cloud-VM backend code — guard
   its CI only (Phase 0).

### Canonical build & test commands (use these exact forms)

```bash
# A. Debug compile check (fast, per-commit sanity):
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-overlay-check build

# B. THE release build (the thing that broke v0.64.163–165; Phase 1 turns this into a script):
CMUX_SKIP_ZIG_BUILD=1 xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -derivedDataPath /tmp/cmux-overlay-release -jobs 1 \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  SWIFT_COMPILATION_MODE=singlefile CODE_SIGNING_ALLOWED=NO build

# C. Unit tests, focused (preferred; substitute the class under test):
xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-overlay-check \
  -only-testing:cmuxTests/<TestClass>
# Verify the log says "Executed N tests" with N > 0.

# D. SPM package tests (updater work in Phase 4):
swift test --package-path Packages/macOS/CmuxUpdater

# E. Shell-script test suite for CI machinery (run the individual scripts):
tests/test_ci_sparkle_build_monotonic.sh
tests/test_nightly_universal_build.sh
tests/test_ci_self_hosted_guard.sh

# F. Workflow syntax lint (install once if missing: brew install actionlint):
actionlint .github/workflows/<changed>.yml

# G. Fork overlay audit (must pass at the end of EVERY phase):
./scripts/fork-overlay-audit.sh
```

**When to build what:** run (A) after every commit that touches Swift. Run (B) at the end of any
phase that touched Swift, the pbxproj, entitlements, plists, or build scripts — this is
mandatory before declaring the phase done; it is the exact build the release runs. Run (F) after
every workflow edit. Run (G) at the end of every phase.

---

## Phase 0 — Neuter the dangerous manaflow leftovers (small, do first)

**Why:** three lanes would do the WRONG thing if ever triggered on the fork.

Tasks:

1. `.github/workflows/update-homebrew.yml` — add a job-level guard to every job:
   `if: github.repository == 'manaflow-ai/cmux'` (it bumps manaflow's Homebrew tap).
   Deliberate future option, out of scope here: re-point this lane at a mochiexists tap if we
   ever want `brew install` distribution. For now it stays gated off; note that option in
   `FORK.md` (see task 7).
2. `.github/workflows/presence.yml` — same guard on every job (it deploys manaflow's
   Cloudflare worker; it already fired once on the fork).
3. `.github/workflows/cloud-vm-migrate.yml`, `cloud-vm-smoke.yml`, `test-depot.yml` — same
   guard. They are dispatch-only and inert, but a mis-dispatch should be a no-op, not an error.
4. Do **not** delete any workflow file (deletions cause delete/modify conflicts on every rebase).
5. Extend `scripts/fork-overlay-audit.sh`: for each file in 1–3, `require_file_contains` the
   guard string. This makes the guards rebase-survivable.
6. `nightly.yml`'s upstream feed URL (`files.cmux.com`) is fixed in Phase 4, not here — but add
   a `require_file_absent "nightly.yml" "files.cmux.com"` audit line in Phase 4, noted here so
   it isn't forgotten.
7. `FORK.md` already exists at the repo root (created 2026-07-02) as the canonical internal
   fork-notes doc (identity values, gotchas, lane map). **Every later phase that changes fork
   reality (Phase 3 identity injection, Phase 4 alpha lane) must update FORK.md in the same
   branch** — treat a stale FORK.md as a failing verification gate. In this phase, just confirm
   it exists and add an audit line: `require_file_contains "FORK.md" "com.cmux-mochi"`.

Verification gate: (F) on each edited workflow; (G) passes; `git diff` shows only `if:` lines
and audit-script additions. No build needed (no Swift touched).

---

## Phase 1 — One canonical release build + a pretag guard that earns its name

**Why:** v0.64.163–165 failed because `release.yml` built with `-jobs 1` +
`SWIFT_COMPILATION_MODE=singlefile` while `ci.yml`'s `release-build` job built without them, so
green CI did not prove the release build compiles.

Tasks:

1. Create `scripts/build-release-universal.sh`:
   - Contains exactly command (B) above, with `-derivedDataPath` (default `build-universal`),
     `-clonedSourcePackagesDirPath`, and an optional `--appicon <name>` passthrough
     (nightly/alpha lane uses `ASSETCATALOG_COMPILER_APPICON_NAME`) as parameters.
   - Flag decision (already made): **keep** `-jobs 1` + `SWIFT_COMPILATION_MODE=singlefile`
     everywhere. v0.64.166 shipped with them; consistency beats speed here.
2. Replace the inline xcodebuild in `release.yml` ("Build universal app (Release)", ~line 307)
   with a call to the script. Preserve the surrounding `if:` conditions and env exactly.
3. Replace the inline xcodebuild in `ci.yml` `release-build` job (~line 1354) with the same
   script call (this job currently omits the two flags — after this change CI proves the real
   release variant).
4. Replace the equivalent build in `nightly.yml` with the script (keep its
   `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly` via `--appicon`).
5. Rewrite `scripts/release-pretag-guard.sh` to run, in order:
   a. `tests/test_ci_sparkle_build_monotonic.sh` (existing check);
   b. `./scripts/fork-overlay-audit.sh`;
   c. CI-green-on-HEAD check: `gh run list --repo mochiexists/cmux-mochi
      --commit "$(git rev-parse HEAD)" --workflow ci.yml --json conclusion,status` — fail unless
      a completed run with conclusion `success` exists for this exact SHA. Support
      `--skip-ci-check` for offline use, printing a loud warning;
   d. Optional `--build` flag that runs `scripts/build-release-universal.sh` locally.
6. Add a shell test `tests/test_release_pretag_guard.sh` following the style of
   `tests/test_ci_self_hosted_guard.sh`: stub `gh` on PATH to return success/failure/missing-run
   JSON and assert the guard's exit codes. Wire nothing into pbxproj (pure shell).
7. **Update the workflow-text guard tests or CI goes red.** Several `tests/test_ci_*.sh`
   scripts grep the workflow YAML for literal strings and run as part of `ci.yml`.
   `tests/test_ci_release_sdk_lane.sh` (line ~57) requires the literal
   `CMUX_SKIP_ZIG_BUILD=1 xcodebuild` in both `ci.yml` and `release.yml` — after this phase
   that literal only exists inside the new script. Inventory every affected test with
   `grep -ln 'xcodebuild\|SWIFT_COMPILATION_MODE\|CMUX_SKIP_ZIG_BUILD' tests/*.sh`, then update
   each to assert (a) the workflows call `scripts/build-release-universal.sh` and (b) the
   flags (`CMUX_SKIP_ZIG_BUILD=1`, `-jobs 1`, `SWIFT_COMPILATION_MODE=singlefile`,
   `ARCHS="arm64 x86_64"`) live inside the script itself. Run every updated test locally and
   confirm each still FAILS when its assertion target is removed (temporarily break the script
   to prove the test bites, then restore).
8. Update `skills/cmux-release/SKILL.md` and the release section of `CLAUDE.md` if the invocation
   changed (it shouldn't — same script name).

Verification gate: run the new script locally end-to-end (this is the mandatory (B) for the
phase — expect ~20–40 min); (E) all three listed scripts plus the new test pass; (F) on the
three workflows; (G) passes. Diff review point: the three workflows must now contain zero
inline `xcodebuild` for the universal app build.

---

## Phase 2 — Workflows → repo variables and minimal guards

**Why:** repo *variables* live in GitHub settings, not files. Every fork value expressible as
`${{ vars.X || '<upstream default>' }}` where upstream already has that pattern = zero file diff.

Tasks:

1. Produce the inventory first and commit it as `plans/fork-overlay-cleanup/workflow-diff.md`:
   ```bash
   BASE=$(git merge-base main upstream/main)
   for f in .github/workflows/*.yml; do git diff "$BASE"..main -- "$f"; done
   ```
   Classify every hunk as: (a) value already parameterized upstream via `vars.*` — revert the
   hunk, record the variable name + fork value to set; (b) fork-structural (release lane, guards,
   caching fixes) — keep, note why; (c) dead-lane guard from Phase 0 — keep.
2. Known (a) candidates: runner labels (`vars.MACOS_RUNNER_26`, `vars.MACOS_RUNNER_26_RELEASE`,
   `vars.LINUX_RUNNER` — the `MACOS_RUNNER_26=cmux-mochi-mini` var is already set on the repo).
   Verify each with `gh variable list --repo mochiexists/cmux-mochi`. **Output the list of
   variables Phil must set; do NOT set them yourself.** Do not revert a hunk until its variable
   is confirmed set or listed for Phil.
3. For hunks that are fork-structural but larger than needed, shrink them to the minimal stable
   form (e.g. a single guarded step rather than a rewritten job).
4. Add to `fork-overlay-audit.sh`: a hunk-count budget. For each of `release.yml`, `ci.yml`,
   `nightly.yml`, compute `git diff $(git merge-base main upstream/main)..main -- <file> |
   grep -c '^@@'` and fail if it exceeds a recorded budget (set the budget to the post-Phase-2
   actual counts; the audit fails if the overlay *grows*).

Verification gate: (F) on every touched workflow; (G) passes; workflow-diff.md committed with
every hunk accounted for; the vars-to-set list is in your report. No Swift touched → no (B),
but run (A) once as a smoke check that the checkout is sane.

---

## Phase 3 — Identity injection at package time

**Why:** `nightly.yml` already proves the pattern: build an upstream-shaped app, then stamp
bundle ID / name / feed / icon with PlistBuddy **before signing**. Doing the same for stable
removes the identity edits from `Resources/Info.plist`, the entitlements files, and the pbxproj
(`PRODUCT_NAME`) from the source diff — the category that silently reverts on every rebase.

Tasks:

1. Extract the injection logic from `nightly.yml`'s "Inject nightly identities and metadata"
   step into `scripts/inject-fork-identity.sh <app-path> <stable|alpha>`:
   stable → name `cmux Mochi`, bundle `com.cmux-mochi`, feed
   `https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml`, icon
   `AppIcon`; alpha values come from Phase 4. It must set CFBundleIdentifier, CFBundleName,
   CFBundleDisplayName, SUFeedURL, URL-scheme entries, and rename the `.app` — mirror every key
   the nightly step currently sets, plus anything `verify-app-bundle-channel-metadata.sh` checks.
2. Wire it into `release.yml` between build and codesign. **Order is load-bearing:**
   build → inject → sign → notarize → verify. Injection after signing invalidates the signature.
3. Wire the existing `scripts/verify-app-bundle-channel-metadata.sh <app> stable` into
   `release.yml` right after injection (it currently exists but confirm it runs in the lane;
   add if missing).
4. Now revert the *identity-only* hunks in `Resources/Info.plist` and pbxproj `PRODUCT_NAME`
   toward upstream — **one file per commit**, and after each revert run (A) plus
   `scripts/inject-fork-identity.sh` against the built app followed by
   `verify-app-bundle-channel-metadata.sh`. If a hunk is NOT identity (e.g. a fork feature needs
   a plist key), keep it and record it in the audit script.
   **ENTITLEMENTS ARE EXCLUDED — do not revert `cmux.entitlements`,
   `cmux.release.entitlements`, or `cmux.nightly.entitlements` toward upstream.** Upstream's
   versions hardcode manaflow's signing identity (`com.apple.application-identifier =
   7WLXT3NR37.com.cmuxterm.app`, `com.apple.developer.team-identifier = 7WLXT3NR37`); the fork
   deliberately removed those keys. Entitlements are sealed into the code signature at signing
   time — plist injection cannot correct them afterward, and signing our cert (team
   `599WAZ6282`) against manaflow's application-identifier produces a broken or rejected
   bundle. The three entitlements files stay as retained fork diffs. Add audit lines:
   `require_file_absent` for `7WLXT3NR37` in all three entitlements files.
5. **Deliberate exception — do not revert:** `UpdateFeedResolver.swift`'s fallback URL must stay
   pointing at `mochiexists/cmux-mochi`. If it fell back to upstream's feed, a Mochi install
   with a missing plist key would update itself into upstream cmux. Add an audit line asserting
   the mochiexists URL is present in that file.
6. Local dev implications: `reload.sh --tag` already stamps its own dev identities — verify a
   tagged Debug build still gets a tagged bundle ID after the pbxproj revert (build one with
   `./scripts/reload.sh --tag overlay-p3` and inspect its Info.plist with PlistBuddy).
7. Update `fork-overlay-audit.sh`: assert `inject-fork-identity.sh` exists and contains the
   stable bundle ID + feed URL; assert release.yml calls it before the signing step (grep order
   check is fine: injection step name must appear before "codesign" in the file).

Verification gate: (B) full release build, then run injection + verify script against the
produced app for the stable channel; (A); (C) on `AuthEnvironmentTests` and
`TerminalAndGhosttyTests` (bundle-ID-sensitive suites); (E) `tests/test_nightly_universal_build.sh`;
(F); (G). Report must include the PlistBuddy dump of the injected app's identity keys.

---

## Phase 4 — Alpha lane (rename nightly, dispatch-only, fork-controlled feed)

**Why:** Phil wants a prerelease he ships exactly when he wants. The nightly lane is already
dispatch-only on the fork but still half-wired to manaflow (feed URL `files.cmux.com`).

Decisions already made — implement as stated:
- **Keep the filename `nightly.yml`** (renaming = delete/modify conflict on rebase). Change the
  workflow display `name:` to `Alpha build`.
- Separate-app model (like nightly today): name `cmux Mochi ALPHA`, bundle
  `com.cmux-mochi.alpha`, URL scheme `cmux-alpha`.
- Feed: rolling GitHub prerelease tag `alpha` on `mochiexists/cmux-mochi` (upstream uses the
  same rolling-tag pattern for its Nightly release). Feed URL:
  `https://github.com/mochiexists/cmux-mochi/releases/download/alpha/appcast.xml`.
- Versioning: `<base>-alpha.<build>`; build number baseline read from the alpha appcast (reuse
  the appcast-baseline logic in `scripts/bump-version.sh`). The alpha app is a separate bundle
  with its own feed, so no cross-channel build reservation is needed — build numbers only need
  to increase within the alpha feed.
- Trigger: `workflow_dispatch` only. Delete the commented-out `push:` block and the
  "decide whether a nightly build is needed" job (its head-vs-nightly-tag comparison is
  meaningless for a dispatch-only lane); keep a `force`-free simple dispatch.
  **Removing `decide` is not a one-hunk delete** — the workflow has ~38 references to
  `needs.decide` / `decide.outputs.*`. Mechanical checklist, verify each with a final
  `grep -n 'decide' .github/workflows/nightly.yml` returning zero hits:
  a. remove `decide` from every job's `needs:` list;
  b. replace `needs.decide.outputs.head_sha` (checkout `ref:`, build-SHA env, release body)
     with `github.sha`;
  c. replace `needs.decide.outputs.short_sha` with a step that computes
     `git rev-parse --short HEAD`;
  d. replace `needs.decide.outputs.should_build` / `should_publish` guards: dispatch-only means
     always build; keep publish gated only on the build job succeeding;
  e. update the rolling-tag movement / current-head guard steps that compared against
     `head_sha`;
  f. update the workflow-text tests that grep nightly.yml:
     `tests/test_ci_nightly_tag_push_auth.sh`, `tests/test_nightly_universal_build.sh`,
     `tests/test_ci_nightly_xcode_selection.sh`, `tests/test_ci_nightly_prune_python_compat.sh`
     — run each after the edit; prove each still fails when its target is broken;
  g. run `actionlint .github/workflows/nightly.yml` — an invalid workflow parses as
     "phantom failure with no jobs" on GitHub, so lint locally, do not discover it by pushing.
- Icon: reuse `AppIcon-Nightly` for now (follow-up ticket: parameterize
  `scripts/generate_nightly_icon.py` for an ALPHA banner). Do not block on iconography.

Tasks:

1. Transform `nightly.yml` per the decisions: identity values, feed URL (audit:
   `require_file_absent` for `files.cmux.com`), publish step targets the rolling `alpha`
   prerelease (create-or-update: upload DMG `cmux-alpha-macos-<build>.dmg` + regenerate and
   upload `appcast.xml` on that tag). Use `scripts/build-release-universal.sh --appicon
   AppIcon-Nightly` and `scripts/inject-fork-identity.sh <app> alpha` from Phases 1/3.
2. `scripts/verify-app-bundle-channel-metadata.sh`: change the `nightly` case to `alpha`
   (expected name `cmux Mochi ALPHA`, bundle `com.cmux-mochi.alpha`, icon `AppIcon-Nightly`).
   Keep accepting `nightly` as a deprecated alias that errors with a pointer, so stale callers
   fail loudly rather than validating the wrong thing.
3. `Packages/macOS/CmuxUpdater/UpdateFeedResolver.swift`: replace the `isNightly` bool with a
   channel classification that recognizes `/alpha/` (and legacy `/nightly/`) path segments;
   update `UpdateDriver+SPUUpdaterDelegate.swift`'s log line and `UpdateStateModelTests`.
   Two-commit red/green: first commit adds the failing test for `/alpha/` classification,
   second the implementation. Run (D) both times, confirm red then green.
3b. **The runtime channel identity is recognized far beyond the updater — update every
   surface.** Known sites (verify and extend with
   `grep -rn 'com\.cmux-mochi\.nightly\|cmux-nightly\|"nightly"' Sources Packages CLI
   --include='*.swift'`, excluding `.build/` checkouts):
   - `Sources/Auth/AuthEnvironment.swift` (~line 49): callback scheme returns `cmux-nightly`
     for the nightly bundle ID — add/rename to `cmux-alpha` for `com.cmux-mochi.alpha`;
   - `Packages/Shared/CmuxAuthRuntime/.../BrowserSignIn/AuthCallbackRouter.swift`:
     `builtInSchemes` set must include `cmux-alpha` or browser sign-in callbacks are rejected;
   - `Packages/macOS/CmuxSettings/.../SocketControl/SocketPathMarkerFiles.swift` and
     `SocketPathVariant.swift`, plus
     `Packages/macOS/CmuxControlSocket/.../Transport/SocketTransport+PathLock.swift`:
     nightly bundle-ID constants, marker-file names, and `/tmp/cmux-nightly.sock` path —
     introduce the alpha equivalents;
   - `Sources/cmuxApp.swift` (~line 4498): channel classification on bundle-ID prefix;
   - also sweep: `Sources/App/StartupBreadcrumbLog.swift`, `Sources/CmuxSSHURLRequest.swift`,
     `Sources/Cloud/PresenceHeartbeatClient.swift`,
     `Packages/macOS/CmuxFoundation/.../CmuxGhosttyConfigPathResolver.swift`,
     `Packages/iOS/CmuxMobileShell/.../MacBuildChannel.swift`.
   Policy: the channel is renamed to **alpha** everywhere user- or filesystem-visible; keep
   the legacy `com.cmux-mochi.nightly` bundle-ID *recognition* paths working (accept both) so
   any lingering installed NIGHTLY app or stale on-disk markers don't misroute sockets or auth.
   Update the paired tests (`SocketPathMarkerFilesTests`, `MacBuildChannelTests`,
   `AuthEnvironmentTests`, `TerminalControllerSocketSecurityTests`) and run (C) for app-target
   suites plus the explicit SPM package tests for every touched package:
   `swift test --package-path Packages/macOS/CmuxUpdater`,
   `swift test --package-path Packages/macOS/CmuxSettings`,
   `swift test --package-path Packages/macOS/CmuxControlSocket`,
   `swift test --package-path Packages/macOS/CmuxFoundation`,
   `swift test --package-path Packages/Shared/CmuxAuthRuntime`, and
   `swift test --package-path Packages/iOS/CmuxMobileShell`. Every one of these files is already
   fork-modified, so this adds no new overlay files.
4. Any new user-visible strings (update pill/popover channel labels if they surface the channel)
   need en + ja entries in `Localizable.xcstrings`. Perform the localization audit and state its
   result in your report.
5. `tests/test_nightly_universal_build.sh`: update expectations to the alpha identity; keep
   filename.
6. Docs: update `skills/cmux-release/SKILL.md` + `references/release-checklist.md` and the
   release section of `CLAUDE.md` with the alpha flow:
   `gh workflow run nightly.yml` → installs/updates only the ALPHA app. Note explicitly that
   stable users can never receive alpha builds (separate bundle + separate feed).
7. `web/app/[locale]/nightly/page.tsx` is fork-modified already — update its copy/link to the
   alpha DMG (en + ja message catalogs).

Verification gate: (D) green with the new resolver tests (and red confirmed on the test-only
commit); (B) + inject `alpha` + `verify-app-bundle-channel-metadata.sh <app> alpha` on the
artifact; (C) on updater-adjacent suites; (E) updated nightly/alpha shell test; (F) on
nightly.yml; (G). **Do not dispatch the workflow** — Phil will run the first real alpha as the
end-to-end test and confirm Sparkle offers an update from the alpha feed.

---

## Phase 5 — App-code seams (worst-first, strictly incremental)

**Why:** `ContentView.swift` carries 51 fork hunks, `AppDelegate.swift` 44, `TabManager.swift`
21 — in upstream's highest-churn files. Goal: each fork feature's body lives in a fork-only
file; the upstream file keeps at most a one-line call site per integration point.

Protocol (repeat per file, one PR-sized branch per file, ContentView first):

1. Map every fork hunk in the file to its feature
   (`git log --oneline $(git merge-base main upstream/main)..main -- <file>` + blame).
2. For each feature, move the implementation into `Sources/Mochi/<Feature>.swift` (new files;
   create the directory; wire new files into the pbxproj) as extensions/helper types. The
   upstream file keeps a single stable call per hook point.
3. **Do not touch the typing-latency contracts:** `TabItemView`'s `Equatable` conformance +
   `.equatable()` call site, `WindowTerminalHostView.hitTest()`'s pointer-event gate, and
   `TerminalSurface.forceRefresh()` must not gain properties, observation, or indirection.
   The recent `fix: split sidebar row modifier chain` commits (fa2520012, fb5a66c90) exist to
   keep Release type-checking tractable — do not re-inline what they split.
4. Behavior must be identical: no signature changes visible to tests, no string changes.
5. After each file: (A); (C) on that file's suites (ContentView → `TabManagerUnitTests`,
   `ShortcutAndCommandPaletteTests`, `OmnibarAndToolsTests`; AppDelegate →
   `TerminalAndGhosttyTests`, `CmuxEventBusTests`; TabManager → `TabManagerUnitTests`,
   `WorkspaceUnitTests`); then (B) — Phase 5 is exactly the kind of change that trips Release
   singlefile type-checking, so the release build is mandatory per file, not per phase.
6. Success metric per file: hunk count in the upstream file drops by ≥60% and every remaining
   hunk is ≤3 lines. Record before/after counts in the audit budget from Phase 2.

Stop after ContentView, AppDelegate, and TabManager. Further files are follow-up work.

---

## Phase 6 — Prepare upstream contributions (PREPARE ONLY)

1. Identify the socket fix and zoom fix commits (see `cmux-mochi-159-backlog` context; locate
   via `git log --grep` for socket/zoom on the fork range) and any generally-useful test
   hardening from the 37 modified test files.
2. For each: create a clean branch off `upstream/main`, cherry-pick + adapt, run (A) and the
   relevant (C) suites against it, and write the PR description to
   `plans/fork-overlay-cleanup/upstream-pr-<name>.md`.
3. **Do not push to any manaflow remote and do not open PRs or issues** — manaflow-ai is not
   Phil's org; he opens these himself after review.

---

## Definition of done / final report

- Phases 0–4 merged to `main`; Phase 5 done for the three named files; Phase 6 branches local.
- `./scripts/fork-overlay-audit.sh` enforces: dead-lane guards, identity injection presence +
  ordering, resolver fallback URL, `files.cmux.com` absence, and hunk-count budgets.
- Final report must include: per-phase commit list; the repo variables Phil must set; before/after
  overlay stats (`git diff --stat $(git merge-base main upstream/main)..main | tail -1` and
  hunk counts for the three Phase-5 files); every test suite run with pass/fail and the
  pre-existing-failure baseline diff; anything skipped and why.
- No tags created, no workflows dispatched, no releases published, nothing pushed to manaflow.
