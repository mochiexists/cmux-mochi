# Account-free reconnect v5: paired device identities, SSH-style

**Status:** design v5, not started. Full architectural pivot after Codex rounds
1–4 (audit: `DESIGN_review_history.md`) and operator direction 2026-08-02.
**Branch:** `mochi/on-v0.64.20-wip`
**Supersedes:** v1–v4's server-issued durable credential ("grant") designs.

---

## The problem (unchanged)

A phone paired without an account cannot reconnect after a cold launch; every
launch needs a fresh QR scan. Upstream's durable half is the Stack account
session; the fork removed accounts and kept only the disposable attach ticket
(`MobileAttachTicketStore` is in-memory, `shouldReconnectStoredMac` demands
`stackAuthenticated`, and the reconnect loop won't dial a stored raw Tailscale
route — `MobileShellComposite.swift:1897–1968`).

## Why v1–v4 died, in one sentence

Every design that had the Mac **issue a secret** grew, under review, an
idempotent-issuance protocol, sealed replay material, recovery verbs, rotation
state machines, and finally a transcript-binding hole in its bespoke proof
scheme (round 4) — because server-issued bearer credentials are the wrong
primitive. SSH solved this thirty years ago by never issuing anything: **the
durable credential is a keypair that never leaves its device; the server just
remembers public keys.**

## Comparators studied (2026-08-02)

- **LM Studio LM Link**: account-anchored (their hub) over embedded tsnet.
  Rejected: accounts are what this fork exists to remove. Lesson kept: don't
  invent a credential lifecycle — reuse one that exists.
- **Local-AI-Chat "Model Link"**: no ceremony; bearer token via synced iCloud
  Keychain + endpoint inventory via iCloud KVS; tailnet for transport.
  Lessons kept: the KVS endpoint-inventory idea (as an *optional module*,
  §9); the dev-build Keychain access-group trap; the stale-serve self-probe.
  Rejected as foundation: external distribution cannot assume a shared Apple
  ID or iCloud at all.

## Decisions locked by the operator

1. Core = SSH-style one-time key exchange via QR. Works tailscale-only, no
   iCloud, no account. Keys local, non-synced.
2. iCloud KVS/Keychain sync is an optional enhancement layer, never a
   dependency. **Not in cmux round 1** (iCloud entitlements for the fork need
   team sign-off).
3. One protocol, packaged for reuse by both cmux-Mochi and Local-AI-Chat
   (§10): cmux policy = QR always; Local-AI-Chat policy (later) =
   KVS-primary, QR-fallback.

---

## Architecture

### 1. Device identity

Every app instance (phone and Mac) generates, at first need, a static
**Curve25519 identity** wrapped in a self-signed certificate, stored as a
`SecIdentity` in the **local (non-synced) Keychain** — `kSecAttrSynchronizable
= false`, `kSecAttrAccessibleAfterFirstUnlock`. Private keys never leave the
device, never transit any network or sync fabric, and are never known to the
other side. Identity is per app instance (bundle id + instance tag), so
Stable/Nightly/tagged-dev builds on one Mac are distinct pairable devices —
mirroring how `MobilePairedMac.pairingID` already treats them.

### 2. Transport security: mutual TLS 1.3 with pinned identities

Connections between paired devices run TLS 1.3 over the existing TCP byte
transport (Network.framework `NWProtocolTLS` /
`sec_protocol_options_set_verify_block`, client identity via
`sec_protocol_options_set_local_identity`):

- **Phone → Mac**: verification is a **pin match** — the presented leaf's
  SPKI (public-key) SHA-256 fingerprint must equal the stored pin for this
  paired Mac. No CA, no chain, no trust store; a self-signed cert is a key
  carrier, nothing more.
- **Mac → phone**: mTLS client-certificate required; the client leaf's SPKI
  fingerprint must be in the Mac's **authorized-devices table** (§4). Unknown
  fingerprint ⇒ handshake fails before any RPC exists.

Everything — enrollment deposit, RPC, session traffic — rides inside this
channel. There is **no bearer token on the wire**, so the round-3/4 relay
attacks (bearer capture, verb/parameter substitution against HMAC proofs)
have no object: a relay cannot complete either side of the handshake, and TLS
1.3 binds the channel keys to both certificates by construction — no bespoke
transcript discipline for us to get wrong.

*Documented alternative if TLS framing fights the existing wire protocol:*
a Noise-IK handshake (CryptoKit: Curve25519 ECDH, HKDF-SHA256, ChaChaPoly,
hashed transcript with domain separation) with the same pin/table semantics.
TLS is preferred because Apple implements it; hand-rolled Noise re-opens the
class of round-4 bugs. Reviewer: treat a switch to Noise as needing its own
scrutiny.

### 3. Pairing (QR, once per device pair)

The QR is re-purposed from credential-carrier to **fingerprint-carrier**:

- QR payload: routes (as today) + the Mac's SPKI fingerprint + a short-lived
  **one-time enrollment ticket** (existing ticket machinery, 10-min TTL,
  single-use, in-memory — its only power is authorizing one enrollment).
- Phone scans → dials the route → TLS with the Mac's pin from the QR (server
  authenticated from the first byte — no TOFU: the QR *is* the out-of-band
  fingerprint channel) → inside the channel calls
  `mobile.pairing.device.enroll {ticket, device_label}`. The phone's own
  certificate arrived as the mTLS client identity; enrollment binds label +
  fingerprint into the authorized-devices table. Mac fires a user
  notification naming the label.
- **Idempotent by construction**: re-enrolling an already-known fingerprint
  updates the label/last-seen and consumes nothing. A lost response costs one
  QR re-scan of a code still on screen — no replay material, no recovery
  verbs, nothing orphaned. (This retires v3–v4's §5a apparatus entirely.)
- A photographed QR ⇒ the thief can enroll **their own** device within the
  ticket's ≤10-min single-use window, visible via the enrollment
  notification and `device.list`. Materially better than v1 (30-day bearer in
  the QR) and v4 (1-h window, silent until first mint): shorter window,
  single-use, named, notified.
- The enrollment verb exists **only inside a pinned-TLS channel**; it is
  absent from the plain network dispatch and from Iroh-admitted connections.

### 4. Authorized-devices table (the Mac's `authorized_keys`)

Persistent store, repository-actor owned, loaded before the listener reports
ready:

- Row: `{spki_fingerprint, device_label, created_at, last_seen_at}`.
- Contains **no secrets** — fingerprints and labels. Confidentiality is not
  required; **integrity is** (a writer can authorize themselves), so it lives
  in the local Keychain (or a root-owned-perms file; Keychain preferred, it's
  already imported). Versioned envelope `{version: 1, devices: []}`; corrupt
  or unknown-version ⇒ treated as empty, loudly logged, every phone re-pairs.
- Quotas: ≤16 devices; enrollment throttled (1/min); one enrollment per
  ticket.
- The phone's mirror: per paired Mac (`pairingID`), store the Mac's SPKI pin
  + routes + label in the local Keychain. `MobilePairedMac`'s "auth tokens
  are never persisted" doc-comment gets rewritten: no *tokens* are persisted;
  a public-key pin is.

### 5. Connection admission

A completed mTLS handshake with an authorized client fingerprint admits the
connection as a new authorization context — sibling of the existing pattern:

- `MobileHostConnectionAuthorizationContext` gains
  `.pairedDevice(fingerprint, label)` alongside `.stackBearer` /
  `.irohAdmission` (`MobileHostTransportAuthorization.swift:14`). Like Iroh
  admission, per-RPC bearer auth is bypassed; scope is mac-wide (pairing is a
  mac-scope act; workspace-scoped *sharing* keeps today's short-lived tickets
  unchanged).
- The connection registry indexes paired-device connections by fingerprint,
  exactly as it does Iroh bindings by `bindingID`
  (`MobileHostConnectionRegistry`), so revocation can close them.

### 6. Revocation

- `mobile.pairing.device.list` / `mobile.pairing.device.revoke
  {spki_fingerprint}` — **local control socket only** (same placement rule,
  and the same explicit absent-from-network-dispatch test, as v2–v4
  demanded). CLI round 1; UI later.
- Revoke deletes the row and closes that fingerprint's live connections via
  the registry. No families, no minted children to chase — one row, one
  device, done.
- No rotation. Key lifetime = until revoked, exactly like `authorized_keys`.
  Stated as an intentional decision (SSH's own model; dogfood threat model
  with controlled tailnet membership). Key hygiene rotation is possible later
  (enroll new, revoke old) with zero protocol change.

### 7. Reconnect flow and gating

- `shouldReconnectStoredMac` (`MobileRootAuthGate.swift:84`) gains
  `hasPairedDeviceIdentity` (pin + own identity present and readable) rather
  than dropping `stackAuthenticated`. Missing/corrupt/inaccessible Keychain
  state ⇒ clean fall-through to the pairing sheet.
- Flow: dial stored route → mTLS (§2) → admitted → resubscribe. No minting,
  no proofs, no credential exchange — the handshake is the authentication.
- Handshake failure against a live listener (wrong pin — impostor or
  reinstalled Mac) is terminal for that route: fall to re-scan prompt, never
  loop. Codex round-4's "recurring unattended relay opportunities" concern is
  resolved structurally: an impostor cannot complete the handshake, so
  auto-redial risks availability only, never credential or session exposure.

### 8. Endpoint discovery (account-free, no KVS)

Carried from v4, unchanged in substance:

- The Mac persists its successfully-bound port per instance tag and prefers
  rebinding it; Tailscale node IPs are stable. Steady state: stored route
  stays valid across Mac restarts.
- Phone tries stored route, then the instance's preferred port. Both failing
  or pin-mismatching ⇒ "scan to reconnect". No port scans, no broadcast.
- Accepted residual: a port stolen during the restart window costs one
  re-scan (availability, not security — §7).
- E2E covers the port-steal-and-restart case proving the failure is the
  re-scan prompt, not a hang.

### 9. Optional enhancement module: shared-KVS discovery (NOT round 1)

Design hook only, so the package boundary is right from day one: a
`DeviceLinkDirectory` protocol — "publish my current endpoints", "observe
peers' endpoints/fingerprints" — with the core consuming it if present.
iCloud KVS implementation (Local-AI-Chat-style: non-secret endpoint + pubkey
inventory under the shared Apple ID, enabling zero-QR enrollment among
same-account devices) ships later: for cmux only after the team clears iCloud
entitlements for the fork; for Local-AI-Chat as its primary path with QR
fallback. Nothing in §§1–8 may depend on it.

### 10. Packaging for reuse

The protocol core ships as a dependency-light SwiftPM package (working name
`DeviceLinkKit`) under `Packages/Shared/`: identity store, pin store,
authorized-devices repository, TLS parameter construction + verify blocks,
QR payload coding, enrollment DTOs, `DeviceLinkDirectory` hook. No cmux
types, transport injected as a byte stream, platform = iOS + macOS.
cmux-Mochi integrates it round 1; Local-AI-Chat can adopt it to replace its
bearer-token layer later (out of scope here). Package API gets DocC and its
own test target per repo architecture rules.

### 11. Scope, transports, and carried constraints (binding, from rounds 1–4)

- **Tailscale-only**; Iroh admission is backend-signed and remains untouched.
  New verbs absent from Iroh-admitted and plain-TCP dispatch; E2E forces
  Tailscale.
- **Sign-in semantics**: local pairings hidden while signed in, reappear on
  sign-out (matches `MobileShellComposite+Scope.swift:16,61`); tested.
- Threat wording honest: an enrolled thief (photographed QR, §3 window) has
  full mac-scoped terminal access until revoked; tailnet gating and
  enrollment notifications bound it. An attacker reading the Mac's Keychain
  owns the Mac already (and there are no secrets in the table anyway).
- Node/app granularity: identity is per app instance, not per human.
- Stale doc-comments updated with the code (`MobilePairedMac.swift:4`,
  `MobileAttachTicketStore` header, `CmxPairingQRCode` comment).

---

## Test plan

**Unit — identity, enrollment, admission**
- enrollment: valid ticket + new fingerprint ⇒ row + notification; reused
  ticket ⇒ refused; expired ticket ⇒ refused; re-enrollment of known
  fingerprint ⇒ idempotent update, no quota consumption; label bounds; quota
  and throttle enforcement
- enrollment verb unreachable outside a pinned-TLS channel; absent from
  network/Iroh dispatch (explicit test, as is `list`/`revoke` absence)
- admission: unknown client fingerprint ⇒ handshake failure, no connection
  registry entry; authorized fingerprint ⇒ `.pairedDevice` context, mac-wide
  scope; workspace-share tickets still scope independently
- pin verification: wrong server key ⇒ phone aborts in handshake, falls to
  re-scan state; no retry loop
- revocation: row removed ⇒ live connections for that fingerprint closed
  (registry test), future handshakes fail; other devices unaffected
- store: round-trips restart; corrupt/unknown version ⇒ empty + loud log +
  re-pair path; tagged-app isolation (per-instance identity and table —
  import Local-AI-Chat's access-group lesson: assert two bundle
  ids/instance tags cannot read each other's identities)
- gating truth table for `hasPairedDeviceIdentity` incl. inaccessible
  Keychain
- scope transitions: no-account pair → sign in → relaunch → sign out →
  reconnect, Mac present in both scopes

**E2E on hardware (force Tailscale; release build per the `#if !DEBUG` trap)**
1. Pair phone → M5, no account. Connected.
2. Force-quit, cold launch: reconnect, **no scan**.
3. Restart cmux on the Mac: phone reconnects (sticky port).
4. Port-steal during restart: phone lands on the re-scan prompt, no hang.
5. Pair M4 too; both Macs connected (regression: `d8f17712c4`); screenshot
   blue + green workspaces in one list.
6. Second phone enrolls off a fresh QR: distinct row, distinct label,
   notification fires; revoking it doesn't disturb phone 1.
7. > 1 h idle: connection persists or re-establishes with no user action (no
   ticket expiry in the loop anymore — verify nothing else times it out).
8. Revoke phone 1 from the Mac CLI mid-session: connection closes, phone
   falls to pairing sheet.
9. Impostor test: wrong listener on the stored port (self-signed cert with a
   different key) ⇒ phone shows re-scan prompt, sends no RPC.
10. Old-client sanity: a build predating DeviceLinkKit pairs via today's QR
    ticket flow exactly as before.

**Suites**: CmuxMobileShell (606) + host authorization/store + MobileRPC +
MobileTransport + MobileWorkspace + control-socket + Iroh + new DeviceLinkKit
target. Two-commit red/green policy for regression tests.

### Test tooling that already works (do not rediscover)

```bash
# mint a ticket (password: pineapple)
CMUX_SOCKET_PASSWORD=… "/Applications/cmux Mochi NIGHTLY.app/Contents/Resources/bin/cmux" \
  rpc mobile.attach_ticket.create '{"ttl_seconds":3600,"scope":"mac"}'

# drive the phone, no taps needed
xcrun devicectl device process launch --device <id> --terminate-existing \
  --environment-variables '{"CMUX_DOGFOOD_ATTACH_URL":"…"}' dev.cmux.ios.nightly
xcrun devicectl device process openURL --device <id> "<cmux-ios-dev://…>"
xcrun devicectl device capture screenshot --device <id> --destination shot.png
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier dev.cmux.ios.nightly \
  --source "Library/Application Support/cmux-debug.log" --destination log.txt
```

### Verification traps paid for already

- `lsof` cannot see these connections (userspace Tailscale) — use
  `netstat -an | grep <port>`.
- `strings` in the binary does not prove a string is shown — edit the
  `.xcstrings` catalog too.
- The pairing port changes when another instance holds the preferred port —
  §8 makes it sticky; the steal case remains and is an E2E case.
- `sync.subscribe_ok` / `liveness probe_ok` do NOT prove a Mac connection —
  confirm Mac-side.
- Never open a cmux session or dev build in `/`.
- (New, from Local-AI-Chat) a stale advertised endpoint can 502 silently for
  weeks — the Mac self-probes its advertised route and surfaces failure.

---

## Definition of done

- Cold launch reconnects with no scan, on the **release** nightly, on
  hardware; M4 + M5 simultaneously, screenshotted.
- DeviceLinkKit exists as a package with its own tests and DocC.
- Codex has approved this design and reviewed the implementation diff.
- Full suite list green; red/green regression commits included.
