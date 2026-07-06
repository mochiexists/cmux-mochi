# Brief: rebase cmux-mochi onto upstream, re-apply fork config, build v0.64.157

## Mission
In an **isolated git worktree**, rebase the Mochi fork onto current upstream, re-apply every fork-specific config value that upstream overwrites, bump to the next version per our scheme, and **prove it worked by building the app and running the unit tests successfully**. Do **not** push, tag, or publish — this is a validation pass. Report what conflicted, what config you re-applied, and the build/test result.

## Context (read before starting)
- Repo: `/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-clean`. Remotes: `origin` = `mochiexists/cmux-mochi` (the fork), `upstream` = `manaflow-ai/cmux`.
- Canonical fork branch: **`mochi/release`** (tip has tag `v0.64.156`, build 101). Do NOT work on it directly.
- Divergence: fork is **71 ahead / ~395 behind** `upstream/main`; last common base ≈ **2026-06-13**. `origin/main` is a useless upstream mirror — ignore it.
- **Why this is dangerous:** upstream bakes in ITS OWN identity/signing/Sparkle/Sentry/release-pipeline values. A clean rebase **reverts all of them to upstream**. The bulk of this task is detecting and re-applying the fork values (checklist below). This has bitten us before.
- Conflict surface (measured via `git merge-tree`): **~31 files** — 5 CI/release (mechanical re-apply), 5 project/build (pbxproj/xcstrings/web-messages/bonsplit, mechanical), ~14 Swift (real merge), 6 tests. Hot spots: `Sources/ContentView.swift`, `Sources/Workspace.swift`, `Sources/GhosttyTerminalView.swift`, `Sources/Panels/{BrowserPanel,PanelContentView}.swift`, `Sources/WorkspaceContentView.swift`, `CLI/cmux.swift`.

## Step 1 — worktree
```bash
cd /Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-clean
git fetch upstream main
git worktree add -b mochi/rebase-on-upstream /private/tmp/cmux-mochi-rebase mochi/release
cd /private/tmp/cmux-mochi-rebase
git submodule update --init --recursive vendor/bonsplit
```

## Step 2 — rebase
```bash
git rebase upstream/main
```
Resolve conflicts per the guidance below. The historical per-release version-bump commits (`0.64.151`…`0.64.156`) will collide on `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`/`CHANGELOG.md`; resolve those by **keeping upstream's version line** and **keeping ALL the fork's CHANGELOG entries** — the real version is set in Step 4. If granular per-commit replay of those release commits is too noisy, an interactive rebase that squashes the release-bump/release-fix commits into the config re-apply is acceptable; the **end state** matters, not the granular history.

### Conflict-resolution guidance by area
- **Release pipeline** (`.github/workflows/release.yml`, `nightly.yml`, `ios-testflight.yml`, `perf-activation.yml`): take the **fork** side wholesale, then verify against the config checklist. Critically, the fork's `release.yml` has a **Ghostty-CLI-helper SHA-cache** (a `Restore cached Ghostty CLI helper` step keyed `ghostty-cli-helper-<sha>-...` + an always-run `lipo -verify_arch`) — that must survive.
- **Drag-and-drop / sidebar between workspaces** (`Sources/ContentView.swift`, `Sources/Sidebar/SidebarBonsplitTabWorkspaceDropOverlay.swift`, `Sources/TerminalPaneDropTargetView.swift`, `Sources/DetachedFolderDragIcon.swift`, `Sources/SidebarWorkspaceGroupConfigOpener.swift`, `Packages/CmuxWorkspaces/.../WorkspaceGroupCoordinator.swift`, `Sources/Panels/PanelContentView.swift`, `Sources/WorkspaceContentView.swift`): **preserve the fork's sidebar spring-load** (drag a session onto a workspace to switch — commits `f78134c6c`, `61a8b0df0`, `7febafc71`, `dc6c05c1e`). Note upstream's "workspace group drag-drop intent" (#6532) was **REVERTED** (#6713), so it is NOT active on upstream — do not resurrect it; but upstream's "one-step grouped workspace creation" (#6657) and "move to group" (#6662) **stayed** — keep those. Goal: fork spring-load AND upstream group-creation coexist.
- **Show/Copy IDs overlay** (`Sources/ContentViewIdentifierCopyCommands.swift`, `Sources/WorkspaceSurfaceIdentifier*.swift`, `Sources/SurfaceIdentifierDetailsWindowController.swift`, `vendor/bonsplit`): keep the fork's overlay + the bonsplit `.showIdentifiers` tab action. bonsplit pointer must stay `122b99cb...` (mochiexists/bonsplit).
- **Resume / `RestorableAgentSession`**: keep `snapshot.resumeCommand` emitting the `.alias` form (cxy/ccy). **Do NOT re-introduce** the reverted codex rollout-existence restorability change (we deliberately removed it — `RestorableAgentSession.swift` should match the 155/156 baseline for `.codex` restorability: lenient `record.isRestorable != false`). Keep the resume tests expecting `cxy`/`ccy` aliases.
- **pbxproj / xcstrings / web/messages**: union both sides' entries; never drop fork-added files or localized keys. After resolving, `plutil -lint cmux.xcodeproj/project.pbxproj` must pass.

## Step 3 — RE-APPLY FORK CONFIG (the whole point — upstream values leak back on rebase)
Audit and fix every item; report each as kept/fixed:
1. **App name** `PRODUCT_NAME = "cmux Mochi"` (Debug `cmux Mochi DEV`); bundle IDs `com.cmux-mochi[.nightly|.debug|.tests|.nightly.universal]`. Upstream uses plain `cmux`/`com.cmux*`.
2. **Team ID `599WAZ6282`** everywhere (upstream's is `7WLXT3NR37`). Do NOT trust a hardcoded file list — **`grep -rn 7WLXT3NR37` and `grep -rn 599WAZ6282`** across the repo and reconcile every hit (pbxproj, `release.yml`/`nightly.yml` provisioning APP_ID checks, `ios/scripts/upload-testflight.sh`, `scripts/mobile-attach-qr-server.sh`, entitlements *if present*). (A prior version of this brief wrongly claimed the entitlements hold team keys — verify, don't assume.)
3. **Sparkle public key in pbxproj** must be the fork key `zuKEVdkteBH5X33sMtjNnINr5JfskPx6Yj4LxZlySfY=`. Upstream's `avjcgKibf1FTvhIjLBxhd+0HSpsXU4D0IGlVk8cgqRc=` leaks in on rebase — `grep -rn avjcgKib` and replace every hit.
4. **Sparkle feeds:** stable `https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml`; nightly `https://files.cmux.com/nightly/appcast.xml`. **`grep -rn 'releases/latest/download/appcast'` and `grep -rni 'cmuxterm\|manaflow-ai/cmux'`** to find every feed/repo ref and fork-align it. Known locations: `Resources/Info.plist` SUFeedURL, `scripts/sparkle_generate_appcast.sh`, `scripts/build-sign-upload.sh`. (The Swift files `UpdateFeedResolver.swift`/`UpdateState.swift` named in a prior draft DO NOT EXIST — find the real fallback via grep, don't assume those paths.)
5. **Repo refs:** `release.yml` and `nightly.yml` must target `--repo mochiexists/cmux-mochi` (not `manaflow-ai/cmux`).
6. **Sentry:** org `codes-o3`, project `cmux-atlas`, in-app DSN `https://cf9f50c96d0e1872f0f774d70da71b1c@o4510776019910656.ingest.de.sentry.io/4511100296101968` — in `Sources/AppDelegate.swift`, `CLI/cmux.swift`, and `SENTRY_ORG`/`SENTRY_PROJECT` in `release.yml`/`nightly.yml`. Upstream reverts these to `manaflow`/`cmuxterm-macos` + DSN host `o4507547940749312`.
7. **Web/site fork-alignment (the prior draft MISSED this — confirmed leakage points):** `web/data/cmux.schema.json`, `web/app/[locale]/nightly/page.tsx`, `web/app/[locale]/components/site-footer.tsx`, `web/app/lib/download.ts`, `web/app/api/github-stars/route.ts` — grep these (and the rest of `web/`) for `manaflow-ai/cmux`, `cmuxterm`, upstream download URLs, and re-point to `mochiexists/cmux-mochi`.
8. **Runners:** `MACOS_RUNNER_15` / `MACOS_RUNNER_26` repo-var indirection preserved (not hardcoded upstream labels).
9. **R2 guard:** `release.yml`'s appcast R2-mirror step skips cleanly when `CF_R2` creds are absent — verify it still does. **`nightly.yml`'s R2 step does NOT skip cleanly on the fork** (confirmed) — apply the same credential-absent guard there.
10. **bonsplit** submodule URL `https://github.com/mochiexists/bonsplit.git`, pointer `122b99cb...`.

### Step 3b — write & run a fork-overlay audit script (this is the authoritative check, not the list above)
Because a hand-list is unreliable (this brief had stale entries), create `scripts/fork-overlay-audit.sh` that (a) **fails on any FORBIDDEN upstream marker** in shipping files — `7WLXT3NR37`, `manaflow` / `manaflow-ai/cmux`, `cmuxterm`, `avjcgKibf1FTvhIjLBxhd+0HSpsXU4D0IGlVk8cgqRc=`, Sentry host `o4507547940749312`, upstream app name/bundle `com.manaflow`/plain `cmux` product name — scanning `.github/workflows/`, `web/`, `Resources/`, `*.entitlements`, `cmux.xcodeproj/project.pbxproj`, `scripts/`, `.gitmodules`, and the BUILT `.app` bundle's Info.plist; and (b) **asserts REQUIRED fork values are present** — `cmux Mochi`, `599WAZ6282`, `zuKEVdkteBH…`, the mochiexists feed URL, `codes-o3`/`cmux-atlas`, bonsplit pointer `122b99cb`. It must exit non-zero on any violation and print each. This script is the primary success gate and should be left in the worktree for reuse on the next rebase.

## Step 4 — version (our scheme)
Fork versioning = upstream `X.Y.Z` with a **trailing marker digit**; current is `0.64.156` (build 101). Patch-bump to **`0.64.157` (build 102)**:
```bash
./scripts/bump-version.sh patch          # 0.64.156 -> 0.64.157, build auto-increments
./scripts/release-pretag-guard.sh        # must pass: local build > published Sparkle build
```
Add a `## [0.64.157]` CHANGELOG entry summarizing the upstream features pulled in (iOS, workspace groups, sidebar/web work) + that it's a fork rebase. Keep version strictly `^[0-9]+\.[0-9]+\.[0-9]+$` (no `-suffix` — `bump-version.sh`/appcast/guard all reject it).

## Step 5 — BUILD + VERIFY (the success proof)
**Critical caveat (verified): `CMUX_SKIP_ZIG_BUILD=1` does NOT skip everything.** `reload.sh` still zig-builds `cmuxd` (`scripts/reload.sh:969`) and `scripts/ensure-ghosttykit.sh` falls back to `zig build` if no prebuilt GhosttyKit exists. Zig 0.15.2 cannot link on this macOS-26 machine, so a rebase that bumps the **ghostty submodule** or **cmuxd source** will make the local build invoke zig and FAIL. Handle this explicitly:

```bash
# 1) Did the rebase change the zig-built components?
git diff --name-only mochi/release HEAD -- ghostty cmuxd | tee /tmp/zigchanged.txt
GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"

# 2) GhosttyKit: fetch the prebuilt for the (possibly new) SHA. Do NOT '|| true' — a miss is a real blocker.
if ! ./scripts/download-prebuilt-ghosttykit.sh; then
  echo "BLOCKER: no prebuilt GhosttyKit for ghostty SHA $GHOSTTY_SHA. The Swift compile cannot be validated locally"
  echo "without building GhosttyKit on a macOS-15 runner first. Report this and STOP the build step."
fi

# 3) cmuxd: if the rebase changed cmuxd, reload.sh will try to zig-build it (and fail here). Reuse the prior
#    cmuxd binary so the SWIFT build can still proceed (cmuxd itself is validated by macOS-15 CI, not locally).
#    Copy a known-good cmuxd from the last successful build / installed app into cmuxd/zig-out/bin/ before building.

# 4) Debug build — validates the SWIFT/app compile (the actual rebase-correctness signal)
CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag rebase157     # must end "** BUILD SUCCEEDED **"

# 5) unit tests
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-rebase157" \
  -destination 'platform=macOS' CMUX_SKIP_ZIG_BUILD=1 \
  PRODUCT_BUNDLE_IDENTIFIER=com.cmux-mochi.debug.rebase157 \
  -only-testing:cmuxTests test 2>&1 | tail -40
```
What the local build CAN validate: the Swift merge compiles + cmuxTests. What it CANNOT: ghostty/cmuxd zig changes (those build on macOS-15 CI) and release-only signing/feed/notarization. State both in the report.

**Build-number note:** `bump-version.sh` sets build = `max(local, latest-published-Sparkle-build) + 1` (`scripts/bump-version.sh:47`). `0.64.156` published as build **101**, so this yields **102** — but if a newer build was published since, it'll be higher; report the actual number.

**Expected test result:** the 4 pre-existing `SessionPersistenceTests.testHermesAgentHookSurfaceResume*` failures are KNOWN (they fail on 155/156 too, env-sensitive, not a gate). ANY OTHER new failure means the rebase broke something — investigate it. Confirm the conductor skill still bundles: `…/cmux Mochi DEV rebase157.app/Contents/Resources/skills/cmux-mochi-conductor` exists.

## Success criteria
1. `git rebase` completes; working tree clean; `plutil -lint` passes on pbxproj.
2. **`scripts/fork-overlay-audit.sh` (Step 3b) exits 0** — zero forbidden upstream markers across workflows/web/Resources/entitlements/pbxproj/scripts/.gitmodules AND the built `.app` bundle, and all required fork values present. This is the authoritative anti-false-green gate (a Debug build alone misses web/nightly/release-only leakage).
3. `bump-version.sh` → `0.64.157` / build **102** (or higher if a newer build was published — report it); `release-pretag-guard.sh` passes.
4. **`** BUILD SUCCEEDED **`** (Swift compile) and `cmuxTests` shows only the 4 known Hermes failures (no new ones). If ghostty/cmuxd zig changes blocked the local build, that is reported as a CI-must-build item, NOT a silent skip.
5. Conductor skill bundles into the built app.
6. Report explicitly lists: every conflicted file + resolution, the full audit result (markers scanned, any fixed), and what was vs wasn't locally validated.

## Constraints
- Do **NOT** push, tag, or trigger a release. No `git push`, no `gh release`, no tag creation.
- Do **NOT** re-introduce the reverted codex rollout-existence change; keep alias-binding (cxy/ccy) test expectations.
- Do **NOT** delete the worktree on success — leave it at `/private/tmp/cmux-mochi-rebase` for human review.
- Operate only inside the worktree; never touch `mochi/release` or the main checkout.
- Report: conflicted files + how resolved (esp. the drag-drop/sidebar reconciliation), the full Step-3 config audit (each item kept/fixed), and the build + test output.
