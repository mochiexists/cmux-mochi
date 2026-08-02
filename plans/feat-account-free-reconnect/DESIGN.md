# Account-free reconnect v6: paired device identities over pinned mTLS

**Status:** design v6, not started. v5 architecture + Codex round-5 fixes +
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
  protocol. **TLS session resumption disabled** (or fingerprint re-validated
  on every ready handshake) so revocation is never bypassed by a cached
  session (round-5 blocker 5).
- **TLS-only; the legacy plaintext pairing path is deleted** (operator
  decision — zero external consumers, "legacy" was only us):
  - the bearer-token QR field and its grammar
    (`CmxPairingQRCode.swift` `k=`/`x=` handling),
  - `CmxLegacyPrivateNetworkPairingCode` and the
    `.legacyPrivateNetworkCompatibility` route-disclosure mode,
  - the plaintext-TCP attach flow for device pairing and the
    ticket-authorizes-any-RPC network dispatch that existed to serve it,
  - the frozen-client fallback heuristics
    (`shouldFallbackToSyntheticManualTicket` string-matching and friends)
    where their only purpose was pre-DeviceLink clients.
  No dual listeners, no downgrade path, no "if old client then" branches.
  Redundant code is removed in a dedicated cleanup phase with its own commit
  series. (Iroh transport and the local control socket are untouched — they
  are different subsystems, not legacy.)

### 3. Pairing ceremony (QR, once per phone×Mac pair)

QR payload: routes + the Mac's SPKI fingerprint + a **one-time enrollment
ticket** (10-min TTL, single-use). The QR carries **no bearer credential** —
photographing it yields, at most, one visible, named, revocable enrollment
within ten minutes, and only from inside the tailnet.

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
`:1150`) is restructured, not worked around (round-5 major). Mac-wide scope;
workspace-scoped ephemeral **sharing** keeps today's short-lived tickets on
their existing paths.

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
- Flow: dial stored route → mTLS → admitted → resubscribe. Nothing else.
- **Fail-fast on definitive pin mismatch** (round-5 major: today
  `.secureChannelFailed` in `.waiting` idles until the connect deadline —
  `CmxNetworkConnectionEvent.swift:81`): a completed handshake with a wrong
  key is terminal for the attempt → re-scan prompt, no automatic retry
  loop against a cryptographically-refuted endpoint.
- Backoff (imported from T3 Code field practice, improved): exponential
  ladder with **jitter**, reset after 30 s healthy, and
  **foreground-resume bypasses backoff** — app-open is an immediate
  reconnect attempt.
- Endpoint discovery: sticky per-instance port + stable Tailscale IP
  (unchanged from v4/v5 §8); stored route first, preferred port second,
  both failing ⇒ re-scan prompt. Port-steal is an availability event only —
  an impostor cannot complete the handshake.

### 8. Optional module + packaging (unchanged from v5)

`DeviceLinkDirectory` hook for shared-KVS discovery (iCloud KVS
implementation later; cmux round 1 ships without it; Local-AI-Chat adopts
KVS-primary/QR-fallback when it integrates). `DeviceLinkKit` SwiftPM package
under `Packages/Shared/`: identity store, pin store, authorized-devices
repository + coordinator actor, TLS parameter factories + verify blocks, QR
payload coding, enrollment DTOs, reconnect policy constants. No cmux types;
DocC + own test target per repo architecture rules.

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

**Phase 0 — feasibility spikes (throwaway branches, half a day each):**
- a. `swift-certificates` P-256 self-signed leaf + `SecIdentity` assembly +
  `sec_protocol_options_set_local_identity` round-trip on macOS **and**
  physical iOS.
- b. `NWListener`/`NWConnection` mTLS 1.3 loopback with verify blocks both
  ways, ALPN, resumption disabled — the round-5 "prove the key bet" demand.
  Outcome gates the design: if either spike fails, stop and re-plan (the
  Noise-IK alternative is the documented fallback).

**Phase 1 — DeviceLinkKit package:** identity generation/store, fingerprint
canonicalization, pin store, authorized-devices repository actor, enrollment
ticket type + coordinator, TLS parameter factories, QR payload coder,
reconnect policy constants. Full unit coverage incl. the round-5-mandated
loopback TLS integration tests (valid pin, wrong pin, unknown-client with
and without enrollment window, concurrent ticket use, revoke/admit race,
reconnect-after-revoke with resumption attempted, plaintext rejection).

**Phase 2 — Mac integration:** listener TLS parameters; handshake-first
admission; `.enrollmentCandidate` + `.pairedDevice` contexts; registry
indexing by fingerprint; enroll/list/revoke verbs (control-socket placement
+ dispatch-absence tests); enrollment notification; sticky port
persistence; QR generation switched to fingerprint + enrollment ticket.

**Phase 3 — iOS integration:** per-pair identity lifecycle;
persist-before-enroll ordering; scan flow → enrollment; reconnect gate
`hasPairedDeviceIdentity`; fail-fast pin mismatch; jittered backoff +
foreground-resume; pairing sheet states (re-scan prompt).

**Phase 4 — legacy deletion:** remove the bearer QR grammar, legacy pairing
code paths, fallback heuristics, and the ticket-authorizes-any-RPC network
dispatch (workspace-share ticket scope-checking stays for share links).
Dedicated commit series; each removal accompanied by its dead-code test
deletions. Nothing hacky remains behind flags.

**Phase 5 — E2E on hardware + release validation** (below), then Codex
implementation-diff review, then nightly cut.

---

## E2E device matrix (the run-through)

Fleet: **M5** (primary Mac), **M4** (second Mac), **iPhone 16** (automated
journey), **iPhone 17** (manual human journey). Two journeys, both on the
**release nightly** (`#if !DEBUG` pinning), Tailscale forced.

### Journey A — iPhone 16, fully automated (devicectl, no hands)

Driven by the proven tooling (below). Scripted end-to-end:

1. Enroll to M5 (inject pairing URL via `CMUX_DOGFOOD_ATTACH_URL` env /
   `openURL`). Assert connected; screenshot.
2. Force-quit; cold launch. Assert reconnect **with no scan**; screenshot;
   pull `cmux-debug.log`, assert the mTLS reconnect path (not enrollment)
   ran.
3. Restart cmux on M5. Assert phone reconnects (sticky port). Confirm on
   the Mac side (`netstat`, host log) — not just phone-side liveness.
4. Port-steal case: occupy M5's preferred port, restart cmux (ephemeral
   fallback). Assert phone lands on the re-scan prompt — a clean failure
   state, not a hang.
5. Enroll to M4 as well. Assert both Macs connected simultaneously;
   screenshot the merged workspace list (blue + green) — regression guard
   for `d8f17712c4`.
6. >1 h idle soak. Assert the connection survives or silently
   re-establishes with zero user action (nothing in the loop expires
   anymore — verify nothing else times it out).
7. Revoke iPhone 16 from M5 via CLI mid-session. Assert connection closes
   and phone falls to the pairing sheet; M4 pairing unaffected.
8. Impostor: wrong-key listener on M5's stored port. Assert phone aborts in
   handshake, sends no RPC, shows re-scan prompt.

### Journey B — iPhone 17, fully manual (operator hands, final build)

The human proof that the UX is honest — performed by the operator on the
release nightly once Journey A is green:

1. Fresh install. Scan M5's QR by camera. Expect: enrollment notification
   on the Mac naming "iPhone 17" + fingerprint suffix; connected UI.
2. Kill the app, relaunch cold: reconnects with no scan, no prompts.
3. Scan M4's QR too. Both Macs visible in one list, both live.
4. On M5: `cmux rpc mobile.pairing.device.list` — see both phones with
   sane labels/dates. Revoke **iPhone 16's** fingerprint from M5. Confirm
   iPhone 17 is untouched (cross-device isolation, from the human seat).
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
# drive the phone, no taps needed (proven on iPhone 16)
xcrun devicectl device process launch --device <id> --terminate-existing \
  --environment-variables '{"CMUX_DOGFOOD_ATTACH_URL":"…"}' dev.cmux.ios.nightly
xcrun devicectl device process openURL --device <id> "<cmux-ios-dev://…>"
xcrun devicectl device capture screenshot --device <id> --destination shot.png
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier dev.cmux.ios.nightly \
  --source "Library/Application Support/cmux-debug.log" --destination log.txt

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
