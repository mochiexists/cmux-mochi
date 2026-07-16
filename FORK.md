# cmux Mochi — fork notes (canonical internal reference)

This is the one place for fork-internal facts and gotchas. If reality changes (identity,
release lanes, submodules), update this file in the same branch. Public-facing docs live in
`README.md` / `web/`; contributor rules live in `CLAUDE.md` and `skills/`.

Fork: `mochiexists/cmux-mochi` of upstream `manaflow-ai/cmux`. Single trunk (`main`), rebased
onto upstream **release tags** only (never raw `upstream/main` tip). Overlay-cleanup plan:
`plans/fork-overlay-cleanup/PLAN.md`.

## Identity (canonical values)

| | Stable | Alpha (dispatch-only prerelease) |
|---|---|---|
| App name | `cmux Mochi` | `cmux Mochi ALPHA` |
| Bundle ID | `com.cmux-mochi` | `com.cmux-mochi.alpha` (pre-plan: `.nightly`) |
| URL scheme | `cmux` | `cmux-alpha` (pre-plan: `cmux-nightly`) |
| Sparkle feed | `https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml` | `https://github.com/mochiexists/cmux-mochi/releases/download/nightly/appcast.xml` (pre-plan: `nightly`; Phase 4 renames to `alpha`) |
| Icon | `AppIcon` | `AppIcon-Nightly` (alpha icon is a follow-up) |

Signing: Team ID `599WAZ6282`, Developer ID cert `33FD69D8`, notary profile
`cmux-mochi-notary` (local lane). Verify any built bundle with
`scripts/verify-app-bundle-channel-metadata.sh <app> <channel>`.

## Channel model — there is no in-app toggle

Channels are **separate apps**, not Sparkle channels. The feed URL and bundle identity are
baked into the bundle at package time (CI injection; see `nightly.yml`'s inject step and, once
Phase 3 lands, `scripts/inject-fork-identity.sh`). A stable install can never receive alpha
builds. "Enabling" alpha = installing the ALPHA app next to stable. Nothing builds on a
schedule — every lane is tag- or dispatch-triggered.

## Release lanes

- **Stable:** commit → `./scripts/release-pretag-guard.sh` → tag `vX.Y.Z` → push →
  `release.yml` on the self-hosted runner (`[self-hosted, cmux-mochi-m4pro]`). Never reuse a
  failed tag; cut the next patch.
- **Alpha/nightly:** `gh workflow run nightly.yml --repo mochiexists/cmux-mochi -f force=true`
  (file keeps its upstream name deliberately — renaming causes rebase conflicts). The ad-hoc
  lane defaults to the self-hosted signing runner so it proves the same Mac signing/notarization
  path as stable; choose `runner=hosted-macos-15` only when deliberately validating the hosted
  fallback. Current pre-Phase-4 assets publish to the rolling `nightly` prerelease tag and bake
  the GitHub Release appcast URL into the `cmux Mochi NIGHTLY` app.
- **Local fallback:** `scripts/build-sign-upload.sh` (see local-release-provisioning notes);
  used to ship 0.64.155 when CI was broken.
- The exact Release build (`-jobs 1`, `SWIFT_COMPILATION_MODE=singlefile`, universal) is the
  ONLY build that proves a release will compile — Debug/CI-default builds do not. Run it (via
  `scripts/build-release-universal.sh` once Phase 1 lands) before tagging.

Operational playbook: `docs/release-process.md`.

## Submodules — all re-pointed at mochiexists forks

`.gitmodules`: `ghostty`, `vendor/bonsplit` (the window-pane/split engine), and
`homebrew-cmux` all point at `github.com/mochiexists/*`.

- **After every branch switch / rebase:** `git submodule update --init` (pointers don't
  auto-update; builds pick up stale checkouts silently).
- **Rebase gotcha:** a rebase can revert `.gitmodules` URLs to manaflow's repos. Re-check the
  three URLs after every rebase (part of the release-path audit below).
- **Ghostty changes:** commit inside the submodule, push to the mochiexists ghostty fork
  **before** committing the pointer in the parent repo (orphaned-pointer risk). Full workflow +
  conflict notes: `docs/ghostty-fork.md`.
- **bonsplit:** same push-before-pointer rule; keep its remote on the fork.

## GhosttyKit / zig gotchas

- zig 0.15.2 cannot link Ghostty artifacts against Xcode 26.5 / SDK 26.4+ (undefined
  `__availability_version_check`); fixed only in zig 0.16. CI builds the Ghostty CLI helper on
  GitHub-hosted `macos-15` for this reason — don't move that job to macOS 26.
- Local release builds: `CMUX_SKIP_ZIG_BUILD=1` + prebuilt/byte-identical GhosttyKit reuse
  (`scripts/download-prebuilt-ghosttykit.sh`, `scripts/ghosttykit-checksums.txt`).
- GhosttyKit rebuilds always use `-Doptimize=ReleaseFast`.

## Release-build type-checking (the v0.64.163–165 incident)

The release lane compiles with `SWIFT_COMPILATION_MODE=singlefile -jobs 1`, which changes
type-checker behavior vs default builds. `TabItemView` in `ContentView.swift` was split
(fa2520012, fb5a66c90) specifically to keep Release type-checking tractable — do not re-inline
those views or fatten SwiftUI modifier chains in typing-hot files. CI green ≠ release compiles
unless CI runs the same flags (unified in overlay-cleanup Phase 1).

## After every upstream rebase (before tagging anything)

The whole release path reverts to upstream on rebase. Audit: runners/labels, `.gitmodules`
URLs (bonsplit!), workflow timeouts, app name / `PRODUCT_NAME`, channel verifier wiring, R2/
asset guard, feed URLs (`files.cmux.com` must NOT appear anywhere). `scripts/fork-overlay-audit.sh`
encodes the checks — run it, don't trust memory.

## Manaflow lanes we deliberately keep gated off

`update-homebrew.yml` (manaflow's tap), `presence.yml` (their Cloudflare worker),
`cloud-vm-*.yml`, `test-depot.yml` — guarded with `if: github.repository == 'manaflow-ai/cmux'`
(overlay-cleanup Phase 0), never deleted (delete/modify rebase conflicts). Future option: our
own tap already exists (`mochiexists/homebrew-cmux`, vendored as a submodule) — re-point the
homebrew lane at it if we ever want `brew install` distribution. Not now.

## Misc gotchas

- `gh` in this repo can default to the **upstream** repo — always pass
  `--repo mochiexists/cmux-mochi`. Also watch gh account drift to `atlascodesai` (can't push
  to mochiexists).
- `create-dmg` can hang; `hdiutil` is the fallback.
- Test files in `cmuxTests/` must be wired into the pbxproj or they silently run 0 tests.
- The ~1100 `cmux/*`/`manaflow/*` branches on origin are mirror noise from the original clone;
  ignore them. Pre-2026-06-27 branch history is archived under `archive/pre-cleanup-20260627/*`.
