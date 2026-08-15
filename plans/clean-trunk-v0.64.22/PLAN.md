# Clean trunk on upstream v0.64.22

Rebuild the fork as ordered, separable layers on a fresh upstream base, so that
future rebases are routine work rather than an event, and so fork-only fixes to
upstream code can actually leave the overlay by being upstreamed.

- **Base:** `v0.64.22` (`ddd4a01bc5`, 2026-08-03) — latest upstream release tag
- **Branch:** `mochi/clean-trunk-on-v0.64.22`
- **Worktree:** `../cmux-mochi-clean-v06422`
- **Replaces:** `mochi/on-v0.64.20-wip` (merge-base `14e3400b95` = v0.64.20, 2026-07-19)

## Why this base

`v0.64.22` already contains both upstream mobile-bandwidth fixes that motivated
this work:

- `da8a58a1a2` — screen-anchored render grids (#8860). Scrolling output no longer
  repaints every row; history growth becomes an exact `scrolled: N` count.
- `69b2c55e27` — bounded mobile event emission with shed-or-close (#8858), plus
  `MobileHostConnectionEventQueue`, which sheds superseded render-grid deltas and
  requests a resync instead of dropping the connection.

No further bandwidth work landed upstream after the tag. Measured seam churn from
our merge-base also favours the tag over `upstream/main` tip, on exactly the files
where our product direction already diverges:

| Seam | at v0.64.22 | at main tip |
|---|---|---|
| `MobileShellComposite.swift` | +4923/−845 | +7025/−1060 |
| `MobileHostService.swift` | +643/−143 | +958/−151 |
| `MobilePairingView.swift` | +60/−67 | +94/−193 |
| `MobilePairingModel.swift` | +2/−9 | +25/−121 |

Upstream gutted the pairing surfaces between Aug 3 and Aug 14 (#9493 "Focus Mac
pairing QR flow on Tailscale" plus the `feat-iroh-product-final` push). Taking the
tip roughly triples the damage on our most divergent, least upstreamable surface.

Absorbing Aug 3–14 becomes the **first routine rebase** after this trunk is green —
which is also the acceptance test for whether the layering worked.

## Inventory

198 fork commits since the merge-base; 479 files (119 added, 360 modified);
+98.7k/−67.7k, of which ~65k is generated `pbxproj` / `xcstrings` churn.

By commit scope tag:

```
devicelink 55   ci     11   sidebar 8   pairing 6   socket 5
mobile     42   ios     9   release  8   fork    6   (long tail: vscode 3,
session 3, taskmanager 2, settings 2, privacy 2, capture 2, artifacts 2,
cli 2, apns 2, skills, shell, welcome, workspaces, sentry, updater, …)
```

Connection work (`devicelink` + `mobile` + `pairing` + `ios`) is 112 of 198.

## Layers

Apply in order. Each layer is a contiguous commit series with one job, one
upstreamability verdict, and its own re-application method. **Design rule for
every layer: push logic into fork-owned files and leave only thin call-sites in
upstream files.** The number of upstream lines we touch is the thing that
determines the cost of the next rebase.

### L0 — Fork identity

Bundle IDs, app names, URL schemes, Sparkle feed URLs, icons, Team ID `599WAZ6282`,
Sentry gating, and `.gitmodules` re-pointed at the `mochiexists` forks (ghostty,
bonsplit, homebrew-cmux — confirmed reverted to `manaflow-ai` at the base).

- Upstreamable: **never**
- Method: prefer injection (`scripts/inject-fork-identity.sh`, overlay-cleanup
  Phase 3) over patching, so identity is configuration rather than diff
- Canonical values: `FORK.md`

### L1 — CI and release lanes

Workflow guards, runner variables (`MACOS_RUNNER_*`), the self-hosted release lane,
the alpha/nightly dispatch lane, `scripts/fork-overlay-audit.sh`.

- Upstreamable: **never**
- Method: guard manaflow-only lanes with `if: github.repository == 'manaflow-ai/cmux'`;
  never delete them (delete/modify conflicts on every future rebase)
- Keep `nightly.yml` named as-is — renaming causes rebase conflicts

### L2 — Upstreamable fixes

Fork fixes to genuinely upstream code. These should land as clean red/green pairs,
be opened as upstream PRs, and then **leave our overlay permanently**.

- `fix(socket): let capability-wrapped commands use password auth`
- `fix(socket): preserve shell telemetry in password mode`
- `fix(socket): refuse surface.send_text into live non-agent foreground jobs`
- Ticket-expiry subscription drop (see L5 — upstream's `EventSubscription` binds
  no credential lifetime, so a subscription outlives the ticket that authorized it)
- `fix(ios): survive an empty Xcode auth-arg array on bash 3.2`

Verified: `SocketClientAuthorization.swift` exists at the base, so the socket fixes
apply to upstream code, not fork code.

### L3 — DeviceLinkKit

`Packages/Shared/DeviceLinkKit` — 14 sources + 4 test files. Touches **zero**
upstream files and has exactly one consumer package (`CmuxMobileShell`) plus the
Mac target.

- Upstreamable: **candidate** (self-contained package)
- Method: copy wholesale; re-add the workspace group via
  `python3 scripts/check-workspace-package-groups.py --write`

### L4 — DeviceLink host integration

The seams into `Sources/Mobile/MobileHostService.swift`: listener TLS injection,
peer-fingerprint admission, tailnet interface pinning, route publishing.

- Upstreamable: **no** (fork transport policy)
- Method: **rewrite, do not re-apply.** Upstream replaced `startListener()` with a
  generation-based `bindReadyCandidate()` → `adoptCandidateListener()` flow that
  *moves* to a ready candidate port; our version pins the tailnet interface and
  *fails closed rather than moving the port*. These designs disagree deliberately.
- Note: upstream now calls this the **legacy listener** (opt-in, `NWParameters(tls: nil…)`)
  with iroh as the account-authenticated primary. Porting as-is is the agreed
  decision for this pass; moving DeviceLink onto the iroh lane is separate scoped work.

### L5 — Attach-ticket authorization

Ticket-as-authorization, ticket-bound transports, identity disclosure to ticket
callers, and the expiry-driven subscription teardown.

- Upstreamable: **partly** (the expiry binding is an upstream gap — see L2)
- Hazard: our `dropSubscriptionsWithExpiredTickets()` hooks the top of the old
  `sendEvent`. Upstream replaced that path with `MobileHostConnectionEventQueue` +
  `deliverEventFrames`. The hook must move to upstream's new admission point, and
  needs a regression test that fails if it is silently dropped.

### L6 — Accountless pairing UX

The Mac pairing window journey, the "continue without an account" sign-in path,
QR/DeviceLink code minting, and the reconnecting-grace state.

- Upstreamable: **no — this is a product divergence, not a patch.** Upstream is
  demoting QR pairing (#8821, #9493); the accountless QR journey is the fork's
  reason to exist. Expect to re-decide this surface at every sync.
- Orphan: `OnboardingPage.swift` no longer exists upstream; re-home those changes.

### L7 — Mac feature ports

Independent of the mobile stack; port one feature at a time, each with its tests.

sidebar privacy/frost · adaptive right-side placement · Task Manager page ·
sidebar CPU/memory readout · spring-load workspace switch · pane zoom persistence ·
agent resume continuity · welcome catalog · VS Code panes (contentMode,
serve-web workbench registry) · artifacts parity · workspace screenshot capture ·
agent skills bundling · `cx/cxy/cc/ccy` aliases · `cmux send --enter/--wait` ·
Sentry startup policy

- Orphan: `MobileShellComposite+ForgottenMacs.swift` no longer exists upstream.

## Gates

Do not start the next layer until the current gate is green.

| After | Gate |
|---|---|
| L1 | Tagged Debug build: `./scripts/reload.sh --tag clean-trunk` |
| L3 | `swift test` for `DeviceLinkKit` |
| L4–L5 | `CMUXMobileCore`, `CmuxMobileShell`, `CmuxMobileRPC` package tests |
| L6 | Full `cmuxTests` + iOS tests; `scripts/lint-pbxproj-test-wiring.sh` |
| L7 | `scripts/test-unit.sh`; per-feature focused tests |
| Pre-tag | `scripts/fork-overlay-audit.sh`, Release-mode universal build (`SWIFT_COMPILATION_MODE=singlefile -jobs 1`), `scripts/release-pretag-guard.sh` |

The Release build is the only build that proves a release compiles — Debug and
CI-default builds do not (the v0.64.163–165 incident).

## Hazards

- **`Localizable.xcstrings`** — ours +3159/−1699, upstream +11168/−1805. Merge by
  re-adding our keys onto upstream's file; never take one side wholesale.
- **`project.pbxproj`** — ours +204/−31, upstream +3052/−101. Re-add via Xcode or
  the four hand-edited entries; a test file missing its wiring runs 0 tests silently.
- **Orphaned edits** — exactly two files we modified no longer exist upstream
  (`MobileShellComposite+ForgottenMacs.swift`, `OnboardingPage.swift`).
- **Submodule isolation** — verified: linked worktrees get their own
  `worktrees/<name>/modules/<sub>` git dirs, so the clean trunk does **not**
  disturb the existing worktree's ghostty checkout.
- **`CLAUDE.md` itself diverges** — upstream's base version now forbids
  auto-launching background review agents and reports builds as
  `http://127.0.0.1:17320/<tag>` rather than `file://` paths. Reconcile
  deliberately rather than overwriting with ours.
- **zig / GhosttyKit** — zig 0.15.2 cannot link against Xcode 26.5 / SDK 26.4+.
  Use the prebuilt path (`scripts/download-prebuilt-ghosttykit.sh`,
  `CMUX_SKIP_ZIG_BUILD=1`).
- **`gh` defaults to upstream** in this repo — always pass
  `--repo mochiexists/cmux-mochi`, and check for account drift to `atlascodesai`.

## TestFlight

Only after every gate is green. The fork rides its own `v1.x` train (latest
`v1.38.1`), independent of upstream's `v0.64.x`.

**A version bump for the beta or stable lane requires explicit approval** — building
is always fine, bumping is not.
