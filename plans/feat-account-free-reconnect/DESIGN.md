# Account-free reconnect v7: paired device identities over pinned mTLS

**Status:** design v7, not started. v5 architecture + Codex round-5/6 fixes +
comparator imports (T3 Code study 2026-08-02). Audit: `DESIGN_review_history.md`.
**Branch:** `mochi/on-v0.64.20-wip`
**Operator decisions honored here:** SSH-style QR key exchange as the core;
tailscale-only; iCloud KVS as optional later module; shared `DeviceLinkKit`
package; **zero external consumers ⇒ no legacy compatibility — redundant
pairing code is deleted, not fenced**.

---

## Problem (unchanged from v1)

A phone paired without an account cannot reconnect after a cold launch. The
fork removed the durable half of upstream's two-part credential system
(account session + disposable ticket) and kept only the disposable half.

## Architecture summary

Each app instance holds asymmetric identities; devices exchange **public**
keys once at pairing; connections are mutual-TLS with fingerprints pinned both
ways; admission is connection-level. No server-issued durable secrets, no
rotation, no bearer credentials at rest, no plaintext transport.

Validated by review as resolving the round-4 attack class ("TLS 1.3, once
implemented correctly, genuinely resolves the transcript-binding and
active-relay substitution class" — round 5) and independently endorsed by the
T3 Code comparator study, whose own weakest point is plaintext LAN transport
and whose lesson list literally reads "put the cert fingerprint in the QR."

### 1. Device identity (per pair, P-256)

- **P-256 signing identities** (round-5 blocker: Curve25519/X25519 is
  key-agreement only and cannot sign TLS certificates; Security.framework
  key types are NIST curves).
- Self-signed X.509 leaf generated via **Apple's `swift-certificates`**
  package (Security.framework has no public self-signed constructor — this is
  the named, vetted path; prove on physical iOS + macOS in phase 0). Validity
  100 years — expiry is not the revocation mechanism, the table is; expiry
  behavior is therefore "ignore notAfter beyond parse validity" and is
  documented, not accidental.
- **Per-pair identities on the phone** (round-5 major): the phone generates a
  distinct identity per paired Mac, restoring v1–v4's per-Mac
  compartmentalization — theft of one key exposes one pairing, and
  fingerprints cannot correlate a phone across Macs. The Mac uses one
  identity per app instance (it is the identified party, not the roaming one).
- Storage: `SecIdentity` in the local Keychain,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (round-5 major:
  `synchronizable=false` alone still permits encrypted-backup migration;
  match the existing Iroh identity precedent). `errSecInteractionNotAllowed`
  (locked) is distinguished from missing — **never** mint a replacement
  identity because the store was temporarily locked.

### 2. Transport: mutual TLS 1.3, pinned both ways, TLS-only

- Network.framework: `NWProtocolTLS` on the Mac's listener and the phone's
  connection. `DeviceLinkKit` ships **parameter/options factories** (verify
  blocks, local identity) which the existing transport receives at
  construction time — round-5 major: TLS must be configured when the
  `NWConnection`/`NWListener` is created, not injected into a byte stream
  later; `CmxNetworkByteTransport` (`CmxNetworkByteTransport.swift:119`) and
  the Mac listener (`MobileHostService.swift:872`) accept injected parameters.
- **TLS profile (pinned down, round-5 major):** TLS 1.3 min and max;
  server sets `sec_protocol_options_set_peer_authentication_required(true)`
  (servers default to false); client identity required; certificate
  verification on both sides is exactly "leaf SPKI SHA-256 equals expected
  pin / is in the authorized table" — no chain building, no trust store, no
  hostname check (the pin is the identity). Canonical fingerprint =
  lowercase-hex SHA-256 of the DER SubjectPublicKeyInfo. ALPN
  `cmux-devicelink/1` so the endpoint can never be confused with any other
  protocol. **TLS session resumption unconditionally disabled** so revocation
  is never bypassed by a cached session (round-5 blocker 5; round-7 removed
  the revalidation alternative).
- **TLS-only, client certificate required unconditionally.** Session
  resumption **unconditionally disabled** (not "or revalidate"), and the
  client **verifies the negotiated ALPN** equals `cmux-devicelink/1` rather
  than merely advertising it (round-6 corrections).
- **Tailscale workspace-share links are removed** (round-6 blocker). A
  client-certificate-required listener cannot serve an unpaired share
  recipient (they fail in the handshake before presenting any bearer), and a
  paired recipient already holds mac-wide admission, making a
  workspace-scoped ticket non-authoritative theater. Resolution consistent
  with the zero-consumers ruling: the TCP listener is a **paired-device
  surface only**. Ephemeral cross-person workspace sharing is Iroh's job
  (backend-signed pair grants, upstream mechanism, untouched). If
  account-free per-workspace sharing is ever wanted, it returns as a scoped
  *enrollment* (a table row with a workspace pin), not as a bearer path.
- **The legacy pairing path is deleted** (operator decision — zero external
  consumers, "legacy" was only us). The Phase-4 inventory explicitly
  **partitions deletions from retained code** (round-6 correction):

  *Deleted (device-pairing + TCP ticket surface):*
  - bearer-token QR grammar (`CmxPairingQRCode.swift` `k=`/`x=` fields),
  - `CmxLegacyPrivateNetworkPairingCode` and
    `.legacyPrivateNetworkCompatibility` route-disclosure mode,
  - the plaintext-TCP attach flow and the **entire**
    ticket-authorizes-RPC network dispatch (workspace-share tickets over
    TCP included, per the blocker above),
  - Mac-wide network ticket issuance for pairing
    (`v2MobileAttachTicketCreate`'s pairing role — the control-socket verb
    is retargeted to mint enrollment tickets),
  - the manual/synthetic attach path
    (`syntheticManualHostTicket`, `requestManualAttachTicket`,
    `shouldFallbackToSyntheticManualTicket` string heuristics) — manual "add
    Mac by host:port" survives as UI that accepts the same
    fingerprint+enrollment-ticket payload as the QR, typed instead of
    scanned,
  - temporary attach-ticket root authentication on the phone
    (`attachTicketAuthenticated` gating in `MobileRootAuthGate`) once
    `.pairedDevice` admission replaces it,
  - `MobilePairingModel`'s compatibility routing between Iroh and legacy
    ticket QRs — pairing QRs become DeviceLink-only; Iroh pairing keeps its
    own upstream entry points.

  *Retained (different subsystems, not legacy):* Iroh transport + admission
  wholesale (Iroh uses `.transportAdmission`, not the ticket store —
  `MobileCoreRPCClient.swift:66`); the local control socket; Stack-account
  auth paths for signed-in users. **`MobileAttachTicketStore` itself is
  deleted if migration leaves it unused** — round-7 correction: the live
  store exclusively issues/validates attach bearers, which no longer exist;
  only shared route DTOs/coders still needed elsewhere survive.

  *Also migrated in Phase 4 (round-7 additions):* ticket-derived iOS
  capability policy (`MobileShellWorkspaceMutationTicketPolicy.swift`) and
  the debug/soak scripting that builds attach URLs
  (`scripts/lib/attach-url.mjs` and dependents) — retargeted to the v7
  payload or deleted with their feature.

  No dual listeners, no downgrade branches. Removal is a dedicated commit
  series, each deletion with its dead tests.

### 3. Pairing ceremony (QR, once per phone×Mac pair)

QR payload: routes + the Mac's SPKI fingerprint + a **one-time enrollment
ticket** (10-min TTL, single-use). The QR carries **no durable or
session-grade bearer** — the enrollment ticket *is* a short-lived bearer
capability (round-6 wording correction), and photographing it yields, at
most, one visible, named, revocable enrollment within ten minutes, from
inside the tailnet.

Flow (resolves round-5 blocker 1 — enrollment vs. admission contradiction):

1. Phone generates the per-pair identity, **persists identity + Mac pin
   first** (round-5 major: persist-before-send; a lost enrollment response
   is then recovered by redialing with the same identity — a Mac that
   already committed the fingerprint just admits it as paired; re-scanning
   is never required for a lost response).
2. Phone dials with TLS, presenting its client certificate; server pin from
   the QR is verified — the Mac is authenticated to the phone from the first
   byte.
3. The Mac accepts the **unknown** client certificate only while at least
   one unexpired enrollment ticket exists, admitting the connection as
   **`.enrollmentCandidate(fingerprint)`** — a context whose entire RPC
   surface is `mobile.pairing.device.enroll`. No enrollment window open ⇒
   unknown fingerprints fail the handshake outright.
4. `enroll {ticket, device_label}`: the **enrollment coordinator** (one
   actor) atomically validates ticket expiry/purpose/quota/throttle,
   persists the fingerprint row, and **consumes the ticket only after
   persistence succeeds** — the T3 Code pattern (their conditional
   `UPDATE … WHERE consumed_at IS NULL … RETURNING` has no TOCTOU window;
   ours is the actor-serialized equivalent). Concurrent enrollment attempts
   are serialized so exactly one unknown fingerprint wins a given ticket.
5. Mac fires a user notification: label **plus fingerprint suffix** (labels
   are attacker-controlled: normalized, control-characters stripped, byte-
   capped — round-5 minor). Connection transitions to `.pairedDevice` (or
   closes and redials — whichever the implementation proves cleaner; the
   test asserts the post-state, not the mechanism).

The **enrollment ticket is a new type**, not a `CmxAttachTicket` (round-5
blocker 3: the existing store's tokens are reusable by design and its
generator has a fail-open UUID fallback). Enrollment tickets: CSPRNG or
**throw** (fail closed), single-purpose, consumed exactly once, in-memory
only. T3-style human-friendly encoding (Crockford-alphabet, rejection-
sampled) if we ever surface manual entry; inside a QR it's opaque bytes.

### 4. Authorized-devices table

`{spki_fingerprint, device_label, created_at, last_seen_at}` — no secrets;
integrity-sensitive. Local Keychain, versioned envelope, corrupt ⇒ empty +
loud log + re-pair. Quotas: ≤16 devices, enrollment throttle 1/min, one
fingerprint per ticket. **One repository actor owns the table, admission
finalization, and connection-registry insertion** (round-5 blocker 5): a
revoke is ordered strictly before or after any in-flight admission — either
the handshake verification re-checks and rejects, or the connection is
indexed first and then closed by the same revoke. No window where a
just-verified connection survives an earlier revoke.

Phone-side mirror per paired Mac: `{mac_pin, routes, label, own identity
ref}` in the local Keychain, `…ThisDeviceOnly`.

### 5. Admission

Completed handshake with an authorized fingerprint ⇒
`MobileHostConnectionAuthorizationContext.pairedDevice(fingerprint, label)`
(sibling of `.stackBearer` / `.irohAdmission`,
`MobileHostTransportAuthorization.swift:14`). Admission is **handshake-first
and peer-identity-derived** — the current code path that wraps an accepted
connection with `.stackBearer` before any handshake
(`MobileHostService.swift:1123`, insertion before `transport.connect()` at
`:1150`) is restructured, not worked around (round-5 major). Mac-wide scope.
Ephemeral cross-person sharing lives on Iroh only (§2); the TCP listener
admits paired devices and enrollment candidates, nothing else.

### 6. Revocation

`mobile.pairing.device.list` / `.revoke {fingerprint}` — local control
socket only, with the explicit absent-from-network-and-Iroh-dispatch test.
Revoke = actor removes row + closes that fingerprint's connections (registry
indexes paired-device connections by fingerprint, as Iroh bindings are by
`bindingID`). No rotation; key lifetime = until revoked (SSH model,
intentional). Hygiene rotation later = enroll new + revoke old, zero
protocol change.

### 7. Reconnect

- Gate: `shouldReconnectStoredMac` gains `hasPairedDeviceIdentity`
  (identity + pin present *and readable*; locked-Keychain ≠ missing).
- Flow: dial stored route → mTLS → **round-trip probe** → admitted →
  resubscribe.
- **`.ready` is not admission (proven in spike 0b).** Under TLS 1.3 the
  client's handshake completes *before* the server validates the client
  certificate (client auth rides after the server's Finished), so a phone
  presenting an unknown or revoked identity briefly observes a `.ready`
  connection that the Mac never admitted. The phone therefore treats the
  first successful **request/response round trip** as the connected signal;
  a connection that goes `.ready` and then fails its probe is reported as a
  refusal (re-pair needed), never as "connected". Mac-side truth is its own
  admission record, not the socket state.
- **Fail-fast on definitive pin mismatch** (round-5 major: today
  `.secureChannelFailed` in `.waiting` idles until the connect deadline —
  `CmxNetworkConnectionEvent.swift:81`): a completed handshake with a wrong
  key is terminal for the attempt → re-scan prompt, no automatic retry
  loop against a cryptographically-refuted endpoint.
- Backoff (imported from T3 Code field practice, improved): exponential
  ladder with **jitter**, reset after 30 s healthy, and
  **foreground-resume bypasses backoff** — app-open is an immediate
  reconnect attempt.
- Endpoint discovery (**revised during implementation**): a *fixed* service
  port — the listener binds it or refuses to start, never moving to an
  OS-assigned port. A sticky/ephemeral fallback was tried and rejected: it
  silently changes the address a paired phone was given, which presents as an
  unreachable Mac rather than a moved one. Alongside the numeric tailnet
  addresses the Mac advertises its **MagicDNS name**, which survives a tailnet
  IP change; the stored route set is tried in order, and only when all of them
  fail does the phone reach the re-scan prompt. Port-steal is an availability
  event only — an impostor cannot complete the handshake.

### 8. Optional module + packaging (unchanged from v5)

`DeviceLinkDirectory` hook for shared-KVS discovery (iCloud KVS
implementation later; cmux round 1 ships without it; Local-AI-Chat adopts
KVS-primary/QR-fallback when it integrates). `DeviceLinkKit` SwiftPM package
under `Packages/Shared/`: identity store, pin store, authorized-devices
repository + coordinator actor, TLS parameter factories + verify blocks, QR
payload coding, enrollment DTOs, reconnect policy constants. No cmux types;
DocC + own test target per repo architecture rules.

**Upstream-merge discipline (operator directive):** all new logic lives in
packages; edits to fork-touched upstream files (`MobileHostService.swift`,
`MobileShellComposite*`, transport files) are thin integration seams —
parameter injection, context cases, call-outs into DeviceLinkKit — so future
merges from upstream cmux rebase cleanly. When this ships, the package (and
this design) is the artifact offered back to the team; keep it free of
fork-only assumptions so that conversation is easy.

### 9. Carried constraints (binding, rounds 1–5)

Tailscale-only; Iroh untouched and excluded from new verbs (with tests);
sign-in scope semantics per `MobileShellComposite+Scope.swift:16,61`
(local pairings hidden while signed in), tested; honest threat wording — an
enrolled thief has mac-wide terminal access until revoked; enrollment
notifications + `device.list` + per-family revoke bound it; per-pair
identities bound key-theft blast radius to one Mac; device names are
mildly privacy-sensitive (table confidentiality is "nice", integrity is
"required"). Stale doc-comments (`MobilePairedMac.swift:4`, store headers,
QR comments) updated with the code.

---

## Implementation plan (phased; each phase = small commits + green build)

**Phase 0 — feasibility spikes — ✅ BOTH PASS on macOS 2026-08-02.**
Sources preserved: `spike0a-identity.swift`, `spike0b-mtls.swift`.
- a. ✅ `swift-certificates` P-256 self-signed leaf → `SecCertificate` +
  `SecKey` → resolvable `SecIdentity` → `sec_identity_create` →
  `sec_protocol_options_set_local_identity` accepted with TLS 1.3 pinned;
  canonical SPKI SHA-256 extracted and cross-checked against
  `SecCertificateCopyKey`.
  *Environment notes (harness artifacts, not API limits):* an **unsigned**
  CLI cannot `SecItemAdd` to the data-protection keychain (`-34018`, needs
  an application-identifier entitlement) and legacy-keychain add of an
  ephemeral `SecKey` ref returns `-50`; the spike proved identity resolution
  via PKCS#12 import instead. **Phase 1 must assert the entitled
  `SecItemAdd` path inside a real app target** (iOS device included — that
  half of 0a is still outstanding and is a Phase-1 entry gate).
  Also: macOS 26's OpenSSL 3 requires `-legacy` (or explicit
  `PBE-SHA1-3DES`/`-macalg sha1`) for `security import` to accept a p12 —
  relevant to E2E scripting.
- b. ✅ `NWListener`/`NWConnection` mutual TLS 1.3 on loopback with SPKI
  verify blocks **both ways**, ALPN `cmux-devicelink/1` negotiated and
  verified, `peer_authentication_required(true)`, resumption + tickets
  disabled. Four cases green: happy path (data round-trip + server
  admission), wrong server pin (client refuses the impostor before sending
  data), unknown client (server refuses — no admission, no data), plaintext
  client (no session).
  **Design-affecting finding:** client `.ready` precedes server-side client-
  cert validation under TLS 1.3 → §7's round-trip rule. Caught here rather
  than in production.

### OPEN BLOCKER — Mac identity storage needs a decision (2026-08-02)

**Symptom:** `mobile.pairing.code.create` on a locally built Mac dev build
fails with `identityFailed("keyImportFailed(-34018)")` —
`errSecMissingEntitlement`. Everything else on the Mac side works: the verb
dispatches, the control-socket policy accepts it, routes are published.

**Cause:** `SecIdentityFactory` creates the Mac's TLS identity by adding a
private key to the keychain and reading back the resulting `SecIdentity` —
Security.framework offers no public way to build one without a keychain. A
cmux dev build is signed locally with no provisioning profile, so it carries
neither `application-identifier` nor `keychain-access-groups`, and **both**
keychains refuse the `kSecClassKey` add (the file-keychain fallback added in
`ef11547f14` does not help; the refusal is about entitlement, not routing).
The iOS app is properly provisioned and is **not** expected to hit this.

**This is a build-configuration problem, not an architecture one.** An earlier
draft of this section proposed replacing keychain storage with an in-process
PKCS#12 encoder; that was over-engineering a signing issue and is withdrawn.
Evidence from three experiments:

| dev build signed as | keychain result |
|---|---|
| ad-hoc (Xcode default, `TeamIdentifier=not set`) | `-34018` missing entitlement |
| manually re-signed Developer ID + hardened runtime | `-25304` invalid item ref — a *different*, later failure, so signing genuinely moved it |
| `DEVELOPMENT_TEAM=599WAZ6282` + automatic signing | `-34018` again |

The `-25304` step also exposed a real code bug, since fixed: a key made by
`SecKeyCreateWithData` is not keychain-backed, so adding it by `kSecValueRef`
is invalid. Keys are now created with `kSecAttrIsPermanent`, which is the
supported path.

Remaining gap is almost certainly the missing `keychain-access-groups`
entitlement (a one-line addition to `cmux.entitlements`), not the storage
design. The release app is signed and notarised under team 599WAZ6282 already;
only locally-built dev apps hit this.

**Options (needs an operator/architecture decision):**
1. **Provision the Mac app.** Add `keychain-access-groups` to
   `cmux.entitlements` and sign dev builds with a real profile. Cleanest
   long-term; requires an Apple Developer account signed into Xcode, and
   touches a checked-in entitlements file used by release lanes.
2. **Do not use the keychain for the Mac's identity.** Persist the key
   material in a `0600` file under Application Support and build the
   `SecIdentity` in memory via `SecPKCS12Import` — the approach the Phase 0b
   spike proved works from an *unsigned* binary. Needs an in-process PKCS#12
   encoder (~150 lines) since the p12 is currently produced by shelling out to
   `openssl` in tests. No entitlement dependency at all, on any build.
3. **Keychain on provisioned builds, file fallback otherwise** — option 2 as a
   fallback path only. More code, two paths to keep correct.

**Recommendation: option 2.** DeviceLink already writes its own DER; a p12
encoder is the same class of work, it removes an entitlement dependency from a
security-critical path, and it makes the package work in any harness — which is
also what makes it easy to hand to another app. Option 1 leaves dev builds
unable to pair whenever provisioning lapses.

**What is NOT blocked:** every unit and integration suite (45 + 610 + 34 + 6),
the iOS app archive/install, and the Mac app build. Only a live Mac↔phone
pairing run is gated on this.

### Implementation log (2026-08-02)

- **Phase 1 ✅ shipped.** `Packages/Shared/DeviceLinkKit`, 42 tests green.
  Deviation from plan, deliberately: `swift-certificates` was **dropped**. Its
  X509 product vendors its own Crypto, which collided with the app's in the
  `cmux-unit` scheme (missing `Crypto_*_PackageProduct.framework` at link
  time). DeviceLink needs exactly one certificate profile, so the DER is
  written in-package (`DER.swift`, `SelfSignedCertificate.swift`) and the
  package now has **no external dependencies** — which also makes it easier to
  hand upstream. Correctness is not asserted by inspection: the loopback TLS
  tests only pass if Apple's stack parses these certificates and completes
  mutual authentication with them.
  Bug caught by its own test: concurrent redemptions of one enrollment ticket
  all succeeded, because actors suspend at `await` and persistence sat inside
  the critical section. Fixed by reserving the ticket before the first
  suspension point — exactly the round-5 atomicity blocker, found by a test
  rather than by a user.
- **Phase 2 ✅ shipped.** Listener is TLS-only; admission derives from the
  completed handshake (`.pairedDevice` / `.enrollmentCandidate`); enroll verb
  on the network path, list/revoke on the control socket only (guarded by a
  test that reads the shipping dispatch). 6 host-boundary tests green in the
  app target.
- **Environment note (build):** zig 0.15.2 cannot link the Ghostty CLI helper
  on macOS 26, so a from-source helper build fails here (baseline fails
  identically — unrelated to DeviceLink). **Use the already-built helper, not
  the stub:**

  ```bash
  export CMUX_PREBUILT_GHOSTTY_HELPER="/Applications/cmux Mochi NIGHTLY.app/Contents/Resources/bin/ghostty"
  ```

  That is a real universal Mach-O, so the resulting app is installable — unlike
  `CMUX_SKIP_ZIG_BUILD=1`, whose stub is fine for compiling and unit tests but
  must never be used for a build that goes on a phone.

**Phase 1 — DeviceLinkKit package:** identity generation/store, fingerprint
canonicalization, pin store, authorized-devices repository actor, enrollment
ticket type + coordinator, TLS parameter factories, QR payload coder,
reconnect policy constants. Full unit coverage incl. the round-5-mandated
loopback TLS integration tests (valid pin, wrong pin, unknown-client with
and without enrollment window, concurrent ticket use, revoke/admit race,
reconnect-after-revoke with resumption attempted, plaintext rejection) —
spike 0b's four cases are the seed, extended with server-side admission
assertions rather than socket state.
*Entry gate carried from Phase 0a:* prove entitled `SecItemAdd` +
`SecIdentity` resolution inside a signed app target on macOS **and a
physical iPhone** before building on the identity store.

**Phase 2 — Mac integration:** listener TLS parameters; handshake-first
admission; `.enrollmentCandidate` + `.pairedDevice` contexts; registry
indexing by fingerprint; enroll/list/revoke verbs (control-socket placement
+ dispatch-absence tests); enrollment notification; sticky port
persistence; QR generation switched to fingerprint + enrollment ticket.

**Phase 3 — iOS integration:** per-pair identity lifecycle;
persist-before-enroll ordering; scan flow → enrollment; reconnect gate
`hasPairedDeviceIdentity`; fail-fast pin mismatch; jittered backoff +
foreground-resume; pairing sheet states (re-scan prompt).

**Phase 4 — legacy deletion:** execute the partitioned inventory in §2
(bearer QR grammar, legacy encodings, plaintext ticket dispatch including
TCP share links, manual/synthetic attach machinery, attach-ticket root auth,
`MobilePairingModel` compatibility routing). Dedicated commit series; each
removal accompanied by its dead-code test deletions. Nothing hacky remains
behind flags.

**Phase 5 — E2E on hardware + release validation** (below), then Codex
implementation-diff review, then nightly cut.

---

## E2E device matrix (the run-through)

Fleet: **M5** (primary Mac), **M4** (second Mac), **iPhone 16** (automated
journey), **iPhone 17** (manual human journey). Two journeys, both on the
**release nightly** (`#if !DEBUG` pinning), Tailscale forced.

### Journey A — iPhone 16, fully automated (devicectl, no hands)

Driven by the proven tooling (below). Scripted end-to-end:

1. Enroll to M5 (deliver the pairing URL via `openURL` with the
   `cmux-ios://` scheme — Release has no env-injection path). Assert
   connected; screenshot.
2. Force-quit; cold launch. Assert reconnect **with no scan**; screenshot;
   pull `cmux-debug.log`, assert the mTLS reconnect path (not enrollment)
   ran.
3. Restart cmux on M5. Assert phone reconnects (the port is fixed, so the
   stored route stays valid). Confirm on the Mac side (`netstat`, host log) —
   not just phone-side liveness.
4. Port-steal case: occupy M5's port, restart cmux. Assert the Mac **fails
   closed** — it must report the port as taken and stay stopped, never bind
   elsewhere. Assert the phone reports "can't reach", not a re-pair prompt:
   an unreachable Mac must never destroy a valid pairing.
5. Tailnet IP change: the numeric routes go stale while the MagicDNS route
   still resolves. Assert reconnect succeeds with no scan.
5. Enroll to M4 as well. Assert both Macs connected simultaneously;
   screenshot the merged workspace list (blue + green) — regression guard
   for `d8f17712c4`.
6. >1 h idle soak. Assert the connection survives or silently
   re-establishes with zero user action (nothing in the loop expires
   anymore — verify nothing else times it out).
7. Revoke iPhone 16 from M5 via CLI mid-session. Assert the M5 connection
   closes and M5 shows as needing re-pairing **while the M4 pairing and its
   workspaces remain live and usable in the aggregate UI** — revoking one
   Mac must not dump the phone to a global pairing sheet (round-6
   correction).
8. **Re-enroll iPhone 16 to M5** (fresh QR payload injection): proves
   recovery-after-revoke end-to-end and restores the fleet state Journey B
   expects.
9. Impostor: wrong-key listener on M5's stored port. Assert phone aborts in
   handshake, sends no RPC, shows re-scan prompt for that Mac.

### Journey B — iPhone 17, fully manual (operator hands, final build)

The human proof that the UX is honest — performed by the operator on the
release nightly once Journey A is green:

1. Fresh install. Scan M5's QR by camera. Expect: enrollment notification
   on the Mac naming "iPhone 17" + fingerprint suffix; connected UI.
2. Kill the app, relaunch cold: reconnects with no scan, no prompts.
3. Scan M4's QR too. Both Macs visible in one list, both live.
4. On M5: `cmux rpc mobile.pairing.device.list` — see both phones with
   sane labels/dates (iPhone 16's row is the one re-enrolled in Journey A
   step 8 — Journey B runs after A, sequencing explicit). Revoke **iPhone
   16's** fingerprint from M5. Confirm iPhone 17 is untouched
   (cross-device isolation, from the human seat). Re-enroll 16 afterward if
   continued automation runs are planned.
5. Leave the phone overnight; open it in the morning (foreground-resume
   path): immediate reconnect, no backoff lag perceptible.
6. Airplane-mode the phone, re-enable, foreground: reconnects.
7. Subjective check the automation can't do: pairing sheet copy, scan
   ergonomics, notification wording, "re-scan" prompt comprehensibility.

### Cross-matrix assertions (either journey, once)

- Two phones enrolled on one Mac: distinct rows, distinct fingerprints,
  independent revocation (covered by A7+B4 jointly).
- One phone enrolled on two Macs: distinct per-pair identities on the phone
  (assert distinct client certs presented — pull from Mac-side logs).
- Sign-in/out scope transition with paired Macs present in both scopes.

### Test tooling that already works (do not rediscover)

```bash
# RELEASE-build automation (Journey A runs on the release nightly):
# CMUX_DOGFOOD_ATTACH_URL is DEBUG-only (UITestConfig.swift:46) and Release
# registers the cmux-ios:// scheme, not cmux-ios-dev:// (Release.xcconfig:18)
# — round-6 correction. Drive Release via openURL with the real scheme:
xcrun devicectl device process launch --device <id> --terminate-existing \
  com.cmux-mochi.ios.nightly
xcrun devicectl device process openURL --device <id> "cmux-ios://attach?<v7 payload>"
xcrun devicectl device capture screenshot --device <id> --destination shot.png
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier com.cmux-mochi.ios.nightly \
  --source "Library/Application Support/cmux-debug.log" --destination log.txt
# (CMUX_DOGFOOD_ATTACH_URL + cmux-ios-dev:// remain valid for DEBUG-build
# iteration during Phases 1–3.)

# mac-side (password: pineapple)
CMUX_SOCKET_PASSWORD=… "/Applications/cmux Mochi NIGHTLY.app/Contents/Resources/bin/cmux" \
  rpc mobile.pairing.device.list '{}'
```

### Verification traps paid for already

- `lsof` cannot see these connections (userspace Tailscale) — use
  `netstat -an | grep <port>`.
- `strings` in the binary ≠ string is shown — edit the `.xcstrings` catalog.
- `sync.subscribe_ok` / `liveness probe_ok` do NOT prove a Mac connection —
  confirm Mac-side.
- Never open a cmux session or dev build in `/`.
- A stale advertised endpoint can 502 silently for weeks (Local-AI-Chat
  scar) — the Mac self-probes its advertised route and surfaces failure.
- Keychain access groups differ across build variants (Local-AI-Chat scar):
  per-instance identity isolation is a **test**, not an assumption.

## Unit/integration suites

DeviceLinkKit target (new) + CmuxMobileShell (606) + host
authorization/store + MobileRPC + MobileTransport + MobileWorkspace +
control-socket + Iroh. Two-commit red/green policy for regression tests.
Gating truth table, enrollment/consume atomicity, revoke/admit race, TLS
loopback matrix — enumerated in Phase 1/2 above.

## Definition of done

- Journey A fully green, scripted, on release nightly, on hardware.
- Journey B performed and signed off by the operator.
- Legacy pairing code deleted (Phase 4), no fallback branches remaining.
- DeviceLinkKit package with DocC + tests.
- Codex approved this design and reviewed the implementation diff.
- All suites green; red/green regression commits included.
