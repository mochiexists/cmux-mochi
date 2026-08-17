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
- Ticket-expiry subscription drop — **done** (`031b54d6e0`), ready to upstream: upstream's `EventSubscription` binds no credential lifetime either
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

## Progress (overnight run, 2026-08-16)

Both platforms build on the clean trunk with DeviceLink integrated.

| Layer | State |
|---|---|
| L0 identity | **Done for the app build; partial for the tooling around it.** Generated from `fork-identity.json`; app builds as `cmux Mochi DEV clean-trunk` / `com.cmux-mochi.debug.clean.trunk`. iOS bundle identity is **not** forked yet — the simulator build is still `dev.cmux.ios`. See "Identity leakage in the tooling layer" below: the dev/mobile scripts still spoke upstream identity, which broke pairing outright. |
| L1 CI lanes | **Not started.** |
| L2 upstreamable fixes | **Done** for the socket trio (password-mode capability, shell telemetry, `surface.send_text` guard). Not yet split into PR-ready commits for upstream. |
| L3 DeviceLinkKit | **Done.** Unmodified from the fork; 46 tests in 9 suites pass. |
| L4 DeviceLink host | **Done.** Mutual TLS on both listener sites, fingerprint admission, tailnet enforcement. |
| L5 attach tickets | **Done** for the shared core, transport, and RPC client. |
| L6 pairing UX | **Not started.** The phone still shows upstream's onboarding. |
| L7 Mac features | **Not started.** |

### Verified

- macOS app: `** BUILD SUCCEEDED **`, runs as the fork identity.
- iOS app: `** BUILD SUCCEEDED **` for iPhone 16 Pro simulator; installs, launches, renders.
- Package tests: DeviceLinkKit 46, CMUXMobileCore 346, CmuxMobileRPC 171,
  CmuxMobileTransport 42, CmuxControlSocket 356 — all passing.

### Not verified

- **No end-to-end pairing run.** The simulator app launches but has not been
  paired to a Mac. `~/.secrets/cmuxterm-dev.env` is absent, so
  `ios/scripts/reload.sh` cannot auto-sign-in; run `scripts/setup-team-dev.sh`
  once to enable it. The accountless DeviceLink path should not need it, but
  that path depends on L6, which is not ported.
- **No physical iPhone 16 run.** `xcrun devicectl list devices` shows only
  simulators; no physical device was attached during the run.
- Full `cmux-unit` suite: see the run log; package suites above are green.

### Identity leakage in the tooling layer

The L0 work injected identity into the **Xcode build settings** (pbxproj +
xcconfig). It did not touch the scripts that name the app from *outside* the
app process, and those had reverted to upstream's identity on the clean trunk.

The useful distinction:

- **Self-correcting.** Swift inside the app can ask `Bundle.main.bundleIdentifier`.
  `CLI/CLISocketPathResolver.swift` hardcodes `com.cmuxterm.app.debug`, but only
  as a last-resort fallback after `CMUX_BUNDLE_ID` and `Bundle.main`. Harmless.
- **Load-bearing.** Shell/CI/python that must name the app with no process to
  ask — `defaults write <domain>`, `pkill -f <app path>`, DerivedData paths.
  A wrong literal here fails silently.

`scripts/inject-fork-identity.sh --scan` counts 429 hits / 139 files, but only
**85 hits across 27 files are in the load-bearing external contexts**; the other
317 are in-app Swift (fallbacks and test inputs).

Fixed this run:

| file | was | now |
|---|---|---|
| `scripts/lib/mobile-attach.sh` | `com.cmuxterm.app.debug.<tag>` | `$CMUX_FORK_BUNDLE_ID.debug.<tag>` |
| `scripts/lib/mobile-attach.sh` | `cmux DEV <slug>.app` | `$CMUX_FORK_APP_NAME DEV <slug>.app` |
| `scripts/lib/mobile-attach.sh` | `pkill -f "cmux DEV …"` | fork app name |
| `scripts/cmux-debug-cli.sh` | upstream bundle id + CLI path | fork identity |

`mobile-attach.sh` now sources `fork-identity.env` itself, because several
callers source the lib without sourcing the env.

**Why this mattered.** `cmux_attach_enable_pairing_host` writes
`mobile.iOSPairingHost.enabled=true`, and the comment is explicit that it must
land **before** the Mac app launches (it is read in
`applicationDidFinishLaunching`). It was writing to
`com.cmuxterm.app.debug.<tag>` — a domain no fork build ever reads. The pairing
listener therefore never bound, minting never succeeded, and no phone or
simulator could pair. This presents as a launch-ordering problem, which is
probably the "dev must launch before the main app" symptom remembered from
earlier attempts — but ordering cannot fix it, because the default was landing
in the wrong domain regardless of order.

Verified after the fix: `node scripts/lib/mobile-attach.test.mjs` → 37/37 pass.

**Guard gap.** `--scan` searches only for the upstream *bundle id*. The app-name
literals (`cmux DEV <slug>.app`) contain no bundle id and slipped through.
Scanning for `"cmux DEV "` matches 43 files, mostly Swift test literals, so a
naive gate would block everything; the guard should scan app-name patterns
scoped to load-bearing contexts (`scripts/`, `.github/`, `tests/`, `ios/scripts/`).
Not yet implemented.

### Tag isolation was broken fork-wide (fixed, verified)

The most consequential instance of the identity leak. Two constants held
upstream's debug bundle id:

- `SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier`
- `SocketControlSettings.baseDebugBundleIdentifier`

The tagged app is `com.cmux-mochi.debug.<tag>`, which fails
`hasPrefix("com.cmuxterm.app.debug.")`, so it never resolved as `.dev(slug:)`
and **every tagged Debug build fell back to the single shared
`/tmp/cmux-debug.sock`**. Confirmed by `lsof` before the fix.

Consequences: `cmux-debug-cli.sh --tag` could never reach a tagged app;
`cmux_attach_ensure_mac` timed out on a tagged socket that was never created,
so auto-pair was impossible; and any two builds collided regardless of tag.

Fixed in `aa14254fea` (5 sites incl. stable/debug channel comparisons).
Verified after a tagged rebuild:

- binds `/tmp/cmux-debug-clean-trunk.sock` (was `/tmp/cmux-debug.sock`)
- `CMUX_TAG=clean-trunk scripts/cmux-debug-cli.sh list-workspaces` → `workspace:1`
- iOS pairing listener bound (`*:58465` in the app's TCP listeners)

**Classification rule learned.** An upstream literal is load-bearing when it is
*compared against* the running identity, and harmless when it is only a
*fallback* for it. `CLISocketPathResolver`'s literal is a fallback (it is
reached only after `CMUX_BUNDLE_ID` and `Bundle.main.bundleIdentifier`); these
two were comparisons. An earlier pass in this run wrongly dismissed all in-app
Swift hits as self-correcting, which is how this survived.

### Attach chain: current state

| step | state |
|---|---|
| tagged Mac app builds + launches | ✅ |
| tagged debug socket bound | ✅ `/tmp/cmux-debug-clean-trunk.sock` |
| tag-bound CLI reaches the app | ✅ |
| `mobile.iOSPairingHost.enabled` on correct domain | ✅ |
| iOS pairing listener bound | ✅ `*:58465` |
| iOS app builds + installs to isolated sim | ✅ `cmux-dev-clean-trunk` |
| mint attach ticket | ✅ fixed in `b737095d90` |
| simulator pairs | in progress |

**Mint root cause (fixed).** `MobileAttachTicketStore.compactAttachURL` kept
upstream's round-trip guard `decoded.authToken == nil`. That invariant holds
only where the compact coder strips the token. This fork deliberately encodes
it (`CompactAttachTicket.swift:56` writes `k`, line 74 reads it back) because
the host authorizes on the ticket alone and a signed-out phone must receive the
credential. The guard therefore failed unconditionally, so **every**
`simulator_injection` mint threw `invalidAttachURL`, which the attach scripts
report as `route_representation_unavailable`. The routes were never the
problem: the Mac publishes a valid `debug_loopback` route at `127.0.0.1`,
exactly what a simulator needs. Guard now asserts the token round-trips intact.

This is a third instance of the same porting hazard as the identity leaks: an
upstream invariant retained beside a fork change that invalidates it.

Tailscale is up (`timapple-m5` 100.112.69.84; `iphone172` online), so the
tailnet is not the gap. Next suspect is the ported route layer:
`MobileRouteResolver`, `MobileHostStatusRouteProbe`, `MobileHostTailnetInterface`,
`MobileRouteReachabilityService` — all fork-added and never exercised
end-to-end until now.

Separately, `ios/scripts/reload.sh` refuses to launch unpaired without dev
credentials; `~/.secrets/cmuxterm-dev.env` is absent (one-time
`scripts/setup-team-dev.sh`).

### Test-suite state (not yet attributable)

A `cmux-unit` run reached **3398 passed / 271 failed** before dying at
`** BUILD INTERRUPTED **` under memory pressure — a partial run, not a result.

All 39 failing test files are byte-identical to `v0.64.22`, and failures are
deterministic (two runs, identical counts). A hypothesis that stale
`socketControlMode=automation` caused them was **disproved**: forcing `full`
gave bit-identical results (164/76 for the largest class), and the
`auth pineapple` line that prompted it is the test's own fixture.

Attribution still requires running the same tests on pristine `v0.64.22` in a
scratch worktree. Until that runs, these failures are **unattributed** — not
"pre-existing".

### Accountless pairing: the attach-ticket route is a dead end

The simulator cannot pair over an attach ticket at all, and no amount of fixing
that path changes it. `mobile.attach_ticket.create` returns a ticket whose keys
are `auth_token, expiresAt, macAppBuild, macAppVersion, macDeviceID,
macDisplayName, macPairingCompatibilityVersion, routes, version, workspaceID` --
**no DeviceLink fingerprint**. The phone therefore cannot call
`prepareIdentity(forPairingID:macFingerprint:)`, never pins the Mac, and
`currentPairingTLSOptions()` returns nil. The fork's listener is mutual-TLS
only, so the dial dies before the first byte.

The fork already contains the right answer, and it is better: the **v3
`PairingPayload`** (`MobileHostDeviceLink+Pairing.swift`) carries routes, the
Mac's public-key fingerprint, and a single-use enrollment ticket whose only
power is to add one public key -- and deliberately **no bearer credential**,
because "the previous grammar put a working auth token in the QR, so a
photographed code was usable for the token's whole lifetime". Its
`routeDescription` explicitly accepts `.debugLoopback`, so the simulator is an
intended consumer.

**The Mac never emits it.** The surface is declared in three places and
implemented in one:

| declared | implemented |
|---|---|
| `mobile.pairing.code.create` in `ControlCommandExecutionPolicy` | no worker handler |
| `MobileHostDeviceLink.makePairingURL` | zero callers |
| iOS `PairingPayloadCoder.decode` + `mobile.pairing.device.enroll` | complete |

### Retracted: "tagged control socket stops binding"

This section previously recorded the socket as an unresolved blocker. **That was
wrong.** The socket binds normally; it just takes ~20-40s after launch, and the
checks that reported it absent ran too early. The app was serving
`socket.command.end` the whole time, which a narrow grep had missed.

The lesson worth keeping is the earlier one: a "socket BOUND without my change"
result was a false positive, and working code was reverted on that single bad
signal. Confirm a bind by polling to a timeout, not by one immediate check.

### Account-free pairing works end to end (simulator)

The v3 `PairingPayload` path is now complete and verified on the simulator from
a cold install:

```
decoded code, routes=4
client verify: server d7db2564cd12 expected d7db2564cd12 -> accept
enrolled ok via 127.0.0.1
pairing persisted=true
```

Four separate gaps had to be closed; each was fully implemented but orphaned:

| Gap | Fix |
| --- | --- |
| `makePairingURL` had no caller | `mobile.pairing.code.create` handler (`e0df5cef41`) |
| `connectDeviceLinkPairing` had no caller | route v3 URLs ahead of the ticket decoder (`e4f73182c3`) |
| `deviceLinkEnrollmentResult` had no caller | dispatch at the connection layer (`fca93bc825`) |
| saved-Mac writes silently dropped | resolve the iOS build scope structurally (`6bc7bddfe3`) |

Plus `7d15c4b86e`: the simulator build must be signed or DeviceLink cannot hold
a keychain identity at all (`-34018`).

**L6 pairing UX — done.** `MobileRootAuthGate.isAuthenticated` was
`stack || attachTicket`, so a device that had just paired still rendered the
sign-in screen (`de228f0917`). The simulator now reaches the workspace UI.

### RESOLVED: the MagicDNS route is dialable

Found on the iPhone run: the dial's first attempt failed with `nonNumericPeer`
and only the retry connected, because the route proof requires a numeric peer
while the Mac also publishes `<host>.<tailnet>.ts.net` — the only locator that
survives a tailnet IP change. That durable route was the one route that could
never be dialed.

Fixed in `11a2ac91d2` by resolving the name before proving it; the resolved
address still passes every existing check. On device the dial now connects on
its first attempt instead of after a failure.

### RESOLVED: L5 subscription expiry

`dropSubscriptionsWithExpiredTickets` was never ported and
`EventSubscription` bound no credential lifetime, so a subscription created
with a ten-minute attach ticket streamed for the life of the connection.
Per-request validation cannot cover it: delivery never makes a request.

Fixed in `031b54d6e0`. Enforced by pruning the subscription set on a timer,
**not** in `deliverEventFrames` — the hot fan-out is untouched, and a dropped
subscription simply stops contributing topics, which the existing queue
admission already ignores. A transport downgrade carries the expiry across.

Safe by construction: the expiry defaults to `nil` and `nil` is never
dropped, so a paired device / iroh peer / account session cannot be revoked
by this. Verified on device: a live DeviceLink session ran 70s+ with zero
subscriptions dropped.

Still an **L2 upstreaming candidate** — upstream has the same hole.

### RESOLVED: the phone now pairs, dials, and holds a live session

The account-free path is complete on the simulator. From a cold install, with
no account anywhere in the loop:

```
pairing persisted=true
dial decision … credential=true canConnect=true
post-pairing dial connected=true
sync.subscribe_ok topics=12 transport=renderGrid
changes.summary ok requested=1 summaries=1
sync.liveness probe_ok (repeating)
```

The workspace list renders the Mac's real workspace.

Three more joined halves, in `0c35d4f772` — all of which refused the
connection *before a socket was opened*, which is why the
`deviceLinkTLSOptions` probe never fired and made this look like a network
problem:

1. The RPC client demanded a Stack bearer for any request without an
   `attach_token`, including one whose transport authorizes on its own. It
   failed during request preparation. Fix: consult `transportUsesStackBearer`,
   already false for `.transportAdmission` and `.attachTicket`.
2. The transport factory grouped `.transportAdmission` with `.stackBearer` and
   refused it on both route kinds. Fix: accept it, failing closed when there is
   no identity to offer (`b6d34779fc` pins both directions).
3. The direct-dial branch never named the Mac, so the client could not choose
   which pairing key to offer.

**Physical iPhone: verified** (iPhone 16 Pro Max, over Tailscale, cold install).
Needed three more gates that a simulator never reaches, since it dials loopback
— see `1f28179159`. Sustained session confirmed:
`sync.subscribe_ok topics=12` and repeating `sync.liveness probe_ok`.

### Historical: the DeviceLink dial ran through the bearer machinery

After pairing, the phone must dial the Mac (enrollment closes its own
transport). `ce3ff37439` wires that dial and the `setActiveDialTarget` call it
needs, which gets as far as:

```
dialing stored mac 24d04160-… -> 127.0.0.1:64662 100.112.69.84:64662 …
dial finished: 127.0.0.1:64662 state=disconnected     (~2ms per route)
```

All four routes fail in ~2ms — before any network I/O — and the UI reports
"This pairing route is not trusted" (`mobile.pairing.secureRouteRequired`,
category `.unsupportedRoute`).

Root cause: the stored-Mac dial goes through `connectManualHost` →
`manualHostTicket`, which tries to *acquire an attach ticket* for the route.
That whole path exists to decide whether a route may carry the Stack bearer
(`MobileShellRouteAuthPolicy.routeAllowsStackAuth`). A DeviceLink pairing has
no bearer — the device key is the credential — so the question is inapplicable,
and the answer it produces is a refusal.

Proof the transport is never reached: `deviceLinkTLSOptions` logs
"transport asked for TLS options" on every call, and that line never appears.
The dial dies during ticket acquisition, before any transport is created.

Resolved by `c7e49e4c11`: a Mac this device holds a DeviceLink key and pin for
takes the direct-dial branch, which opens a transport with the pinned identity
instead of exchanging for an attach ticket.

**Not yet done:** the same run on a physical iPhone (deferred at the user's
request while the phones were busy). Per `CLAUDE.md`, iOS work is not complete
until it runs on the phone as well as the simulator.

### Decisions taken during the run

- **zig split.** The clean trunk's ghostty needs 0.16.0, the old worktree's
  needs 0.15.2. 0.16.0 is installed as a sidecar at
  `~/.local/zig/zig-aarch64-macos-0.16.0/`; global `zig` stays 0.15.2, so the
  old worktree is untouched. Build with
  `CMUX_ZIG=$HOME/.local/zig/zig-aarch64-macos-0.16.0/zig`.
- **Entitlements.** The fork removes `keychain-access-groups`,
  `application-identifier`, `team-identifier`, and the web-browser
  public-key-credential entitlement rather than re-teaming them; reproduced
  exactly, because upstream's values name team `7WLXT3NR37`.
- **Name collisions found.** `CMUX_BUNDLE_ID` is an upstream runtime contract,
  so every generated variable is namespaced `CMUX_FORK_*`. Upstream also added
  its own `KeychainDeviceIdentityStore` inside CmuxMobileShell, so the fork's
  client names DeviceLinkKit's explicitly.
- **`PRODUCT_MODULE_NAME` pinned** to `cmux_DEV`: renaming the app product
  renamed the Swift module and broke `@testable import cmux_DEV`.
- One fork hunk was **deliberately dropped**: the privacy-blur guard in
  `controlSurfaceSelect`, which depends on the unported privacy layer. It
  returns with L7.

### Next actions, in order

1. Port L6 (pairing UX) — the phone cannot pair accountlessly without it.
   `OnboardingPage.swift` and `MobileShellComposite+ForgottenMacs.swift` no
   longer exist upstream and need re-homing.
2. Resolve the remaining iOS conflicts: `MobileShellComposite.swift`,
   `+ManualAttachTicket`, `+PairedMacPersistence`, `CMUXMobileRootView`,
   `SignInView`, and the six `WorkspaceList*` / `WorkspaceRow` files.
3. Fork the iOS bundle identity (`ios/Config/*.xcconfig`) the same way as macOS.
4. L1 CI lanes, then L7 Mac features.
5. Re-merge `CmxNetworkByteTransportFactorySecurityTests.swift` — the fork's
   transport security tests are not yet carried.

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
