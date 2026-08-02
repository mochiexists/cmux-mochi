# Plan Review History: feat-account-free-reconnect DESIGN

**Plan File:** plans/feat-account-free-reconnect/DESIGN.md
**Started:** 2026-08-02
**Reviewer:** codex exec, gpt-5-codex, high reasoning, read-only sandbox

---

## Round 1 - Codex Review
**Timestamp:** 2026-08-02T08:47:29Z
**Model:** codex exec default (ChatGPT account), high reasoning, read-only

### Feedback

## Verdict

REQUEST_CHANGES. The design has six blockers. The implementation should not begin until they are resolved in the plan.

### BLOCKER — Rotation can permanently strand the phone

Invalidating the parent before the successor reaches the phone is unsafe:

1. Mac creates and persists successor.
2. Mac invalidates parent.
3. Response is lost, or iOS crashes before updating Keychain.
4. Phone retains only the invalid parent and can never recover without rescanning.

Concurrent rotation requests have the same problem: authorization and ticket creation currently occur as separate operations, so two requests could both validate the parent before either invalidates it. See [MobileHostService.swift:1527](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:1527) and [MobileAttachTicketStore.swift:108](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileAttachTicketStore.swift:108).

Required design:

- Phone persists a random `rotation_id` and pending rotation state before sending.
- Mac atomically validates the parent, creates/persists the successor, and records `parent + rotation_id → successor`.
- Retrying the same rotation returns the same successor. Other uses of the spent parent fail.
- iOS atomically replaces the pending record after receiving the response.
- Persistence failure must leave the parent valid and return an error.
- Test dropped responses, crash-before-Keychain-update, duplicate requests, concurrent requests, and Mac restart between request and retry.

This preserves one active successor while leaving the parent usable only to replay the committed rotation result.

### BLOCKER — A QR ticket is not a per-phone pairing

The ticket contains Mac identity and a bearer token, but no phone identity or grant/family identifier: [CmxTransport.swift:266](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxTransport.swift:266). It is minted before any phone connects at [MobilePairingModel.swift:187](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/Pairing/MobilePairingModel.swift:187).

Consequences:

- Two phones scanning the same displayed QR receive the same durable bearer.
- The first rotation invalidates the other phone.
- The Mac cannot attach a trustworthy device label or revoke “that pairing.”
- The QR itself becomes a photographed 30-day refresh credential; the fork explicitly encodes the token in it at [CmxPairingQRCode.swift:91](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxPairingQRCode.swift:91).
- Older iOS clients will treat the long ticket as an ordinary session ticket and fail when the host enforces mint-only access.

Keep the QR credential short-lived. After the initial connection, add an upgrade/registration exchange that issues a distinct durable grant with a server-generated `grantID`, family ID, issue date, and bounded label. Define whether a QR is single-use or may register multiple phones. This can reuse bearer-token crypto, but it still needs a distinct typed role/DTO; pretending it is an ordinary `CmxAttachTicket` is unsafe.

### BLOCKER — Child scope and lifetime are not server-authoritative

Simply allowing `mobile.attach_ticket.create` in the ticket authorization switch would expose the existing handler, which trusts request parameters for:

- `scope`, including escalation to Mac-wide access: [TerminalController+MobileAttachTicket.swift:13](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/TerminalController+MobileAttachTicket.swift:13)
- route and target selection
- requested TTL

A workspace-scoped parent could request `scope=mac` unless the handler derives the child entirely from the authenticated parent. The plan’s statement that scope is “inherited” is not enough.

Add dedicated atomic store operations such as:

- `mintSession(parentToken:rotationID:)`
- `rotateDurable(parentToken:rotationID:)`

They must revalidate the parent inside the mutation, derive workspace/terminal/family from its record, use server-defined TTLs, and reject scope/TTL/durable-role overrides. Session tickets must have no mint grant.

Also, the claim that `ttl_seconds` already supports any value is false for the public control/RPC path: it is currently capped at one hour at [TerminalController+MobileAttachTicket.swift:8](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/TerminalController+MobileAttachTicket.swift:8).

### BLOCKER — Re-minting does not solve stale endpoint discovery

The phone must reach the Mac before it can present the durable token. When the Mac restarts on a different ephemeral port, the stored route points to the old port. The existing account path solves this by refreshing routes from cloud backup before dialing: [MobileShellComposite.swift:1721](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift:1721). The account-free path has no equivalent authority.

Current reconnect also deliberately does not dial a stored Tailscale route; it only treats Iroh or debug loopback as locally reconnectable: [MobileShellComposite.swift:1884](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift:1884).

The design needs an account-free endpoint-refresh mechanism: a stable per-instance port, tailnet discovery, a stable Iroh rendezvous, or another authenticated discovery record. Add an E2E case where another cmux instance owns the preferred port and the target restarts onto an ephemeral port.

### BLOCKER — Q5 contradicts the current scope model

Signing in does not “change nothing.” Scope resolution chooses the Stack user before the local scope at [MobileShellComposite+Scope.swift:16](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+Scope.swift:16), and explicitly invalidates an existing local scope after sign-in at [MobileShellComposite+Scope.swift:61](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+Scope.swift:61).

Choose and document one behavior:

- Signed-in users see an explicit union of account pairings and local pairings, with credentials selected strictly from each row’s owning scope; or
- Local pairings disappear while signed in.

The current proposal claims the first behavior while the code implements the second. Test no-account pairing → sign in → relaunch → sign out, including a Mac present in both scopes.

### BLOCKER — Iroh bypasses the proposed credential semantics

The preferred pairing code uses Iroh when available: [MobilePairingModel.swift:74](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/Pairing/MobilePairingModel.swift:74). On Iroh:

- iOS selects transport admission regardless of the ticket token: [MobileCoreRPCClient.swift:65](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:65)
- It removes RPC auth entirely: [MobileCoreRPCClient.swift:364](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:364)
- The host authorizes every RPC after Iroh admission: [MobileHostService.swift:1216](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:1216)

Therefore mint-only authorization, ticket rotation, and durable-ticket revocation neither govern nor revoke an Iroh session. A release E2E could pass through Iroh without exercising the new mechanism.

Define whether this feature is Tailscale-only, or how durable-grant revocation relates to Iroh bindings. Force the intended transport in E2E tests. Ensure `list`/`revoke` remain absent from `mobileHostHandleRPC`, including for Iroh-admitted clients.

## Major findings

- **MAJOR — Revocation lacks family semantics.** Revoking only the durable record leaves already minted session tickets and live connections usable for up to an hour. TCP connections are recorded merely as `.stackBearer`, not by ticket family, at [MobileHostService.swift:1123](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:1123). Either revoke the whole family and close bound connections, or explicitly document and test the residual one-hour access window.

- **MAJOR — Persistence contract is underspecified.** Specify schema versioning, corruption behavior, maximum records, persistent pruning, atomic update ordering, Keychain accessibility/synchronization policy, and per-bundle/per-instance service namespace. Physical Mac identity is shared across app variants while `instanceTag` distinguishes them: [MobileHostIdentity.swift:11](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostIdentity.swift:11), [MobileHostIdentity.swift:180](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostIdentity.swift:180). Two tagged apps must never load each other’s grants.

- **MAJOR — Avoid Keychain I/O inside the existing lock.** The store is a global singleton protected by `NSLock`: [MobileAttachTicketStore.swift:15](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileAttachTicketStore.swift:15), [MobileHostService.swift:340](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:340). Introduce an injected repository/actor and an initialization barrier before the listener reports ready. Commit persisted state before publishing it in memory or returning success.

- **MAJOR — Remote minting needs quotas.** A stolen durable token can repeatedly mint thousands of one-hour records, growing `recordsByAuthToken` until expiry. Add per-family rate limits, a maximum number of active session children, a global record cap, and rotation throttling.

- **MAJOR — Token generation must fail closed.** The current generator falls back from `SecRandomCopyBytes` to concatenated UUIDs at [MobileAttachTicketStore.swift:294](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileAttachTicketStore.swift:294). Durable credential creation should throw if the CSPRNG fails. Where practical, persist token digests rather than reusable raw bearers.

- **MAJOR — Reconnect gating should require a usable local credential.** Do not merely remove `stackAuthenticated` from [MobileRootAuthGate.swift:84](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileWorkspace/Sources/CmuxMobileWorkspace/MobileRootAuthGate.swift:84). Pass an explicit `hasUsableDurableCredential`/scope decision so signed-out users with missing, expired, corrupted, or inaccessible Keychain state fall cleanly to re-pairing.

## Minor findings and test additions

- **MINOR — Threat wording is misleading.** A stolen durable token does not get “nothing except” minting: minting yields full Mac-wide terminal access. Rotation only bounds theft if the legitimate phone rotates first; an attacker can rotate first and lock out the owner.

- **MINOR — “Unpairing in the Mac UI” is not currently implementable.** The Mac exposes active connection counts, not phone pairing identities. The actual forget flow is on iOS and cannot guarantee server revocation while offline. Update the plan accordingly.

- **MINOR — Add an absolute family lifetime decision.** Daily rotation otherwise makes the credential indefinitely renewable. Decide whether that is intentional or whether re-pairing is required after an absolute maximum.

- **MINOR — Update stale contracts/comments.** Several files still assert that tickets are short-lived or tokens are never persisted, including [MobilePairedMac.swift:4](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobilePairedMac/Sources/CmuxMobilePairedMac/MobilePairedMac.swift:4).

The test plan must add:

- Lost rotation response and crash recovery
- Duplicate/concurrent rotation
- Persistence failure at every mutation boundary
- Scope/TTL/route escalation attempts
- Session-ticket mint denial
- Multiple scans of one QR
- Old-client compatibility
- Whole-family revoke and active-session behavior
- Keychain corruption/locked/missing state
- Tagged app Keychain isolation
- Iroh versus Tailscale authorization behavior
- Ephemeral-port restart
- Record/rate-limit exhaustion
- Local → signed-in → local scope transitions
- Network denial of `list`/`revoke`

Also run host authorization/store, MobileRPC, MobileTransport, MobileWorkspace, control-socket, and Iroh tests—not only the 606 `CmuxMobileShell` tests. Follow the repository’s two-commit red/green regression-test policy.

In short: a mint-only durable bearer can be viable, and 30 days without background refresh is a reasonable product choice, but not with direct QR issuance, destructive non-idempotent rotation, client-controlled child scope, or unresolved endpoint/Iroh/scope behavior.

**CONSENSUS: BLOCKED — revise the credential issuance, atomic rotation/recovery, authorization derivation, transport, identity, and discovery contracts before implementation.**

---

## Round 1 - Claude Response
**Timestamp:** 2026-08-02T08:51:56Z

### Verification
All six blockers were verified against the source before accepting:
- TTL cap + client-controlled scope confirmed (TerminalController+MobileAttachTicket.swift:8,13,35)
- Sign-in invalidates local scope confirmed (MobileShellComposite+Scope.swift:16,61)
- Iroh admission bypasses per-RPC auth confirmed (MobileHostService.swift:1225); Iroh admission requires backend-signed credentials (CmxIrohAdmissionCredential.swift), so account-free cannot use Iroh at all
- Reconnect never dials stored Tailscale routes confirmed (MobileShellComposite.swift:1897-1968)
- QR carries the bearer token confirmed (CmxPairingQRCode.swift:96)

### Changes Made (design rewritten to v2)
- QR ticket stays 1 h; durable credential moved to a post-connect registration
  exchange (mobile.pairing.grant.register) issuing a distinct typed grant with
  server-generated grant_id/family_id/label — not a long-TTL CmxAttachTicket
- Idempotent rotation protocol with client rotation_id, committed-successor
  replay, pending-state on the phone, persistence-failure -> parent stays valid
- Grant verbs derive scope/TTL entirely server-side; mint-only enforced;
  session children carry no mint capability
- Feature scoped Tailscale-only; new verbs asserted absent from network/Iroh
  dispatch; E2E forces Tailscale
- Endpoint discovery: Mac persists+rebinds its port per instance tag; phone
  verifies host identity via unauthenticated probe before presenting the grant;
  port-steal residual documented + E2E'd
- Scope answer corrected to match code: local pairings hidden while signed in
- Persistence: repository actor (no Keychain I/O under NSLock), digest-at-rest,
  versioned schema, corruption -> empty, init barrier, per-instance-tag
  namespace, quotas, CSPRNG fail-closed
- Family-wide revocation incl. connection closing (with .stackBearer fallback);
  Mac-UI unpair claim withdrawn (CLI round 1)
- Reconnect gate gains hasUsableDurableCredential instead of dropping the
  stackAuthenticated check
- Threat wording fixed; absolute-lifetime decision made explicit (indefinite
  while used, documented)
- Test plan extended with Codex's full list; suite coverage broadened beyond
  CmuxMobileShell; two-commit red/green policy noted

---

## Round 2 - Codex Review (FINAL per skill config, extended per standing loop-until-clear policy)
**Timestamp:** 2026-08-02T09:00:30Z
**Model:** codex exec default, high reasoning, read-only

### Feedback

## Final review

REQUEST_CHANGES. Most round-1 concerns are resolved, but three blockers remain.

### BLOCKER — Rotation replay contradicts digest-only persistence

The plan persists only the successor’s SHA-256 digest ([DESIGN.md:96](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:96)) while requiring retries to return the identical raw successor ([DESIGN.md:133](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:133)). After a Mac restart, the raw bearer cannot be reconstructed from its digest.

Round 1 explicitly required restart-between-commit-and-retry coverage; v2 still lacks that combined test.

Required: persist recoverable replay material—such as a sealed successor bearer or deterministic derivation using a separately protected key—atomically with the rotation record. Define replay retention/pruning and test: commit → lose response → restart Mac → retry same `rotation_id` → receive identical successor.

### BLOCKER — The proposed reconnect handshake cannot safely reach the Mac

The plan requires dialing Tailscale and probing identity before presenting credentials ([DESIGN.md:207](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:207)), but currently:

- Tailscale transport is allowed only in `.attachTicket` mode ([CmxNetworkByteTransportFactory.swift:51](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransportFactory.swift:51)).
- Without an attach token, `MobileCoreRPCClient` chooses `.stackBearer`, which that factory refuses.
- An unauthenticated `mobile.host.status` deliberately withholds Mac identity ([MobileHostService.swift:320](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:320)).
- Merely exposing self-reported `macDeviceID` and `instanceTag` would not authenticate the peer. The transport itself documents that Network.framework cannot prove the generic packet tunnel is Tailscale ([CmxByteTransportRequest.swift:10](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxByteTransportRequest.swift:10)).

Required: define an executable, cryptographically authenticated grant reconnect mode—such as mutual challenge-response using a grant-derived key, or a pinned encrypted channel—so the raw durable grant is never disclosed to an impostor. Include a spoofed-status/port-owner test.

### BLOCKER — Registration is neither replay-safe nor honestly bounded to one hour

A QR holder can call `register`, receive a 30-day grant, and rotate indefinitely. Therefore the claim that a photographed QR remains only a one-hour exposure ([DESIGN.md:81](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:81)) is incomplete: the acquisition window is one hour, but successful compromise can become indefinite.

Registration also has the same lost-response problem: the Mac stores only a digest, so a committed grant whose response is lost becomes an orphan. Repeated retries create families until the 16-grant quota is exhausted.

Required: make registration idempotent with a persisted client `registration_id` and recoverable replay response, and either mitigate durable QR escalation through local approval/single-use semantics or explicitly accept and test that any tailnet QR holder can establish an indefinitely renewable family.

### Round-1 resolution summary

Resolved at the design level:

- Distinct per-phone grants instead of long-lived QR tickets
- Server-derived session scope and lifetime
- Stable-port strategy with documented manual fallback
- Local-versus-signed-in scope behavior
- Tailscale-only scope and Iroh exclusion requirement
- Family revocation, actor-owned persistence, gating, quotas, and fail-closed CSPRNG

Rotation recovery remains incomplete, and the newly specified reconnect/registration protocols expose the blockers above. The working tree is clean and no grant implementation exists outside the plan yet.

**CONSENSUS: BLOCKED - digest-only storage cannot provide restart-safe replay, the reconnect handshake lacks an authenticated executable transport, and registration is not idempotent or honestly bounded.**

---

## Round 2 - Claude Response
**Timestamp:** (same session)

### Verification
- Tailscale transport factory accepts only .attachTicket mode: confirmed
  (CmxNetworkByteTransportFactory.swift:51). Note: the phone CAN dial in that
  mode with a synthetic probe ticket (manual-host flow does today), so the
  transport half was solvable; the authentication half was the real gap.
- Unauthenticated host.status withholds identity: confirmed
  (MobileHostService.swift:320-326).
- Digest-vs-replay contradiction and registration orphan/quota exhaustion:
  confirmed by inspection of my own v2 text.

### Changes Made (v3)
- SS5a replay material: raw successor persisted atomically with the commit,
  erased at first use or 48 h; restart-safe retry returns identical successor;
  post-erasure retry is a terminal re-pair error. Restart-replay tests added.
- SS7a mutual challenge-response handshake: HMAC proofs of K=SHA-256(S) both
  ways, nonce-bound, no existence oracle, successor sealed with
  ChaChaPoly/HKDF; phone aborts before disclosure on impostor; transport rides
  .attachTicket mode via synthetic probe ticket. Spoofed-port test added.
- Registration made idempotent (registration_id, same replay pattern),
  per-QR-ticket cap of 4; Mac fires a user notification on every registration.
- QR escalation stated honestly in SS1/SS10: acquisition <=1 h, compromise
  potentially indefinite; accepted with visibility mitigations; local-approval
  prevention explicitly deferred.

---

## Round 3 - Codex Review
**Timestamp:** 2026-08-02T09:06:12Z
**Model:** codex exec default, high reasoning, read-only

### Feedback

CONSENSUS: BLOCKED - registration recovery remains unimplementable after a Mac restart, and the authenticated handshake does not protect the resulting session bearer.

Two blocker-grade gaps remain:

- Registration retries require the live QR attach ticket, but that ticket is only in memory and disappears on Mac restart ([MobileAttachTicketStore.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileAttachTicketStore.swift:24)). A persisted `registration_id` is not sufficient authorization to retrieve the replay material.
- Initial registration cannot seal `S` using `HKDF(K, …)` when `K = SHA-256(S)`—the phone needs `S` to derive the key needed to decrypt `S`. Rotation does not have this problem because the phone already knows the parent key.
- The handshake authenticates the Mac but establishes no protected channel. `mint_session` produces an ordinary bearer subsequently transmitted as `attach_token` JSON ([MobileCoreRPCClient.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:396)), allowing an active relay to capture it despite valid challenge proofs.

A persisted client-generated registration recovery key/keypair plus sealed replay retrieval would resolve the first two issues. The handshake must also protect or channel-bind the minted session credential and its subsequent use.

The restart-safe rotation material and honest QR-escalation statement are otherwise resolved.

---

## Round 3 - Claude Response
**Timestamp:** (same session)

### Changes Made (v4)
- Client X25519 keypair per registration/rotation (persisted with pending
  state). All issued secrets sealed to it (HPKE-style, CryptoKit). Mac never
  holds raw S at all now - store contains only verifiers + phone-sealed blobs.
  Resolves both the restart-recovery authorization gap (possession of the
  private key IS the retry authorization; register_recover/rotate_recover need
  no live QR ticket) and the HKDF(K)-circularity (sealing key no longer
  derived from the secret being sealed).
- mint_session's session bearer is also sealed to the request's client pubkey
  (defeats passive capture).
- Active-relay risk scoped honestly in SS7a/SS10: a port-squatting relay can
  capture session-tier bearers (plaintext attach_token JSON,
  MobileCoreRPCClient.swift:396) - identical to today's QR-pairing exposure,
  unchanged by this feature; the durable credential never transits in
  capturable form. Accepted for round 1; TLS-pinning / per-request-HMAC noted
  as the upgrade path. Rationale: the handshake's goal is protecting the NEW
  long-lived credential, not upgrading session-tier guarantees beyond the
  status quo this fork already accepts.
- Tests extended: restart-recovery without QR ticket, no-raw-S-anywhere
  assertions, cross-keypair seal rejection, sealed mint_session bearer.

---

## Round 4 - Codex Review
**Timestamp:** 2026-08-02T09:16:17Z
**Model:** codex exec default, high reasoning, read-only

### Feedback

CONSENSUS: BLOCKED - the grant proof is not bound to the requested operation or client public key, so an active relay can steal the durable successor during rotation.

The round-3 registration blockers are resolved: the persisted X25519 keypair enables restart-safe recovery without the QR ticket and removes the circular `HKDF(K)` construction. Sealing `mint_session` also prevents passive bearer capture.

The new blocker is in [DESIGN.md](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:289): `phone_proof` authenticates only the two nonces. An active relay can:

1. Forward a valid challenge.
2. Intercept `rotate`, replacing `rotation_id` and `client_pubkey` with its own—or change `mint_session` into `rotate`.
3. Reuse the unchanged valid `phone_proof`.
4. Receive and decrypt the successor grant sealed to its key.

That converts the acknowledged session-tier relay into durable credential theft.

Required correction: calculate the proof over a canonical transcript containing at least protocol version, `grant_id`, exact verb, both nonces, operation/rotation ID, client public key, and the complete request-body hash. Validate and consume that transcript atomically with the mutation. Authenticate the response envelope under `K` as well. Add mutation tests for verb, public-key, rotation-ID, ciphertext, and metadata substitution.

On the requested session-risk judgment: the status-quo parity argument is not accurate for the stated preferred-port squatter. Today cmux falls back to an OS-assigned port, publishes routes using the actual bound port ([MobileHostService.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:1645)), and the QR encodes that route ([CmxPairingQRCode.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxPairingQRCode.swift:83)). Merely occupying the preferred port therefore does not intercept a fresh QR pairing. Durable reconnect deliberately revisits stored/preferred ports automatically, giving a squatter recurring, unattended relay opportunities. The consequence can remain session-tier once transcript binding is fixed, but the exposure probability is materially increased and needs explicit operator acceptance.

Non-blocking corrections:

- Replace “never stores raw `S`, not even transiently” with “never persists raw `S`”; generation, hashing, and sealing necessarily hold it transiently.
- Remove the contradiction claiming Keychain-held `K` cannot impersonate the phone; §7a correctly acknowledges that it can.
- Specify the X25519/HKDF/ChaChaPoly envelope, domain separation, and authenticated metadata rather than only “HPKE-style.”
- Update the stale “Proposed design (v2)” heading.



---

## Round 4 - Claude Response
**Timestamp:** (same session)

### Disposition: v4 SUPERSEDED, not iterated
Round 4's blocker (phone_proof lacks transcript binding: a relay can swap
rotation_id/client_pubkey or rewrite the verb and steal a durable successor)
is CONFIRMED as a real flaw in the bespoke HMAC protocol - and is exactly the
class of bug that motivated abandoning the bespoke protocol altogether. Its
port-parity correction is also accepted: today's QR encodes the actual bound
port, so a preferred-port squatter does not intercept fresh pairings; durable
auto-reconnect WOULD give recurring unattended relay opportunities - this
needs explicit operator acceptance in any surviving design.

Per operator direction (2026-08-02 session), the design pivots to a two-door
admission model and a v5 rewrite:
- Door 1 (same-tailnet devices): tailnet-identity admission via tailscale
  whois + one-time per-device approval on the Mac. No app-level durable
  credential at all; lifecycle/revocation owned by the Tailscale control
  plane.
- Door 2 (off-tailnet devices): QR one-time keypair ingest with a
  channel-establishing handshake (Noise-class, transcript-bound by
  construction - carrying forward round 4's lesson rather than hand-rolling
  proof binding).
Investigation of Local-AI-Chat's tailscale link and LM Studio's LM Link is in
progress to ground door 1. v5 will be drafted and re-reviewed from scratch;
rounds 1-4 findings remain binding constraints on whatever survives
(idempotency, server-authoritative derivation, endpoint discovery, scope
semantics, Iroh exclusion, honest threat statements).

---

## v5 pivot - operator-directed architecture change
**Timestamp:** 2026-08-02T09:34:33Z

Operator decisions (2026-08-02): SSH-style QR key exchange is the core
(tailscale-only, no iCloud dependency); iCloud KVS demoted to optional module
(not cmux round 1, pending team sign-off on fork entitlements); one shared
package (DeviceLinkKit) targeted at both cmux-Mochi and Local-AI-Chat; cmux
policy QR-always, Local-AI-Chat policy KVS-primary/QR-fallback later.

v5 replaces server-issued grants with per-device static keypairs + mutual
TLS 1.3 pinning (Apple-implemented; Noise-IK documented as the fallback).
No bearer on the wire, no rotation, no replay material, no recovery verbs.
Rounds 1-4 carried constraints preserved in SS11. Comparative investigation
(LM Link, Local-AI-Chat Model Link) recorded in the design's Comparators
section.

---

## Round 5 - Codex Review
**Timestamp:** 2026-08-02T10:05:17Z

### Feedback

## Verdict

REQUEST_CHANGES. TLS is feasible beneath the existing byte framing, but v5 has five blocker-grade gaps.

### BLOCKER — Enrollment contradicts handshake admission

The design requires unknown client fingerprints to fail the TLS handshake, yet enrollment requires that unknown client to finish TLS and invoke `device.enroll` ([DESIGN.md](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:78), [pairing flow](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:100)). The ticket cannot influence certificate verification because it arrives only after TLS.

Required model:

- Require a client certificate.
- Admit an unknown certificate only as `.enrollmentCandidate(fingerprint)`, preferably only while an enrollment ticket exists.
- Restrict that context to enrollment—never general RPC dispatch.
- Atomically enroll, then close/redial or transition to `.pairedDevice`.
- Unknown clients without an active enrollment window must fail the handshake.

The test expecting every unknown fingerprint to fail the handshake must be split accordingly.

### BLOCKER — “Curve25519 SecIdentity” is not an executable API contract

`sec_protocol_options_set_local_identity` requires a `sec_identity_t` carrying a certificate and signing private key ([SecProtocolOptions.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/Security.framework/Versions/A/Headers/SecProtocolOptions.h:89)). X25519 is a key-agreement algorithm and cannot authenticate TLS certificates. The documented Security key types expose NIST EC curves—not Curve25519 ([SecItem.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/Security.framework/Versions/A/Headers/SecItem.h:768)).

Use a supported TLS signing identity, most plausibly P-256, and specify how the self-signed X.509 certificate is created and associated with its Keychain key. Security.framework has no public self-signed-certificate constructor, so the plan must name a vetted certificate-generation/import path and prove it on physical iOS and macOS. Also define certificate validity under the “no rotation” policy.

### BLOCKER — The existing ticket machinery is neither single-use nor enrollment-only

The current store creates reusable bearer tokens and `validAuthorization` does not consume them ([MobileAttachTicketStore.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileAttachTicketStore.swift:26), [lookup](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileAttachTicketStore.swift:108)). The QR explicitly transmits that bearer ([CmxPairingQRCode.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxPairingQRCode.swift:91)). Its generator also retains the round-1 fail-open UUID fallback.

Create a distinct enrollment-ticket type and coordinator that atomically:

1. Validates expiry, purpose, quota, and throttle.
2. Persists the authorized fingerprint.
3. Consumes the ticket only after persistence succeeds.
4. Serializes concurrent uses so exactly one unknown fingerprint wins.
5. Fails closed if secure randomness fails.

### BLOCKER — TLS-only transport conflicts with old-client compatibility

Both sides currently construct plaintext TCP explicitly: the phone at [CmxNetworkByteTransport.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransport.swift:119) and Mac at [MobileHostService.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:872). Replacing the Mac listener parameters with TLS applies TLS to every accepted connection; a pre-DeviceLink plaintext client cannot pair “exactly as before.”

Choose explicitly:

- Drop old-client compatibility; or
- Run separate TLS and legacy listeners/ports and encode distinct routes/credentials.

A v5 client that received a pin must never downgrade to legacy plaintext. If a legacy QR remains available, its photographed bearer exposure must remain in the threat statement.

### BLOCKER — Revocation is not linearizable

The current registry inserts independently of authorization persistence ([MobileHostTransportAuthorization.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostTransportAuthorization.swift:58)). A race can occur:

1. TLS verification observes the fingerprint as authorized.
2. Local revoke deletes it and closes currently indexed connections.
3. The just-verified connection is inserted afterward and survives revocation.

One actor must own authorization rows plus admission finalization and registry indexing, so revoke orders either before admission—causing rejection—or afterward—closing the indexed connection.

Also disable TLS session resumption or revalidate the current fingerprint after every ready handshake. Otherwise resumed sessions could undermine the promise that future handshakes fail immediately after revocation.

## Major findings

- **MAJOR — TLS is layerable, but not through the stated byte-stream seam.** TLS parameters are needed while constructing `NWConnection`/`NWListener`, before a byte stream exists. `DeviceLinkKit` should supply Network.framework option/parameter factories, while `CmxNetworkByteTransport` accepts injected parameters or an already-created connection.

- **MAJOR — Host authorization is currently selected before TLS completes.** The Mac immediately wraps an accepted connection and passes `.stackBearer` ([MobileHostService.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:1123)); registry insertion happens before `transport.connect()` performs the handshake ([MobileHostService.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Sources/Mobile/MobileHostService.swift:1150)). Admission must become handshake-first and peer-identity-derived.

- **MAJOR — Keychain accessibility permits migration.** `kSecAttrSynchronizable=false` prevents synchronization, not encrypted-backup migration. Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, matching the existing Iroh identity precedent, and distinguish `errSecInteractionNotAllowed` from “missing.” Never generate a replacement identity merely because the original is temporarily inaccessible.

- **MAJOR — One static phone key silently expands compromise scope.** Theft of that private key grants access to every paired Mac until each Mac separately revokes it, and the repeated fingerprint makes pairings linkable. V1–v4 had per-Mac credential compartmentalization. Either use per-pair identities or record explicit operator acceptance of this regression.

- **MAJOR — The TLS profile is underspecified.** Require TLS 1.3 min/max, server-side `peer_authentication_required=true`—servers default false ([SecProtocolOptions.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/Security.framework/Versions/A/Headers/SecProtocolOptions.h:562))—a canonical fingerprint format, permitted key algorithm/size, precise leaf extraction, ALPN/version separation, and certificate-expiry behavior.

- **MAJOR — Wrong-pin failure is not presently terminal.** `.secureChannelFailed` in an `NWConnection.waiting` state is allowed to wait until the connect deadline ([CmxNetworkConnectionEvent.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkConnectionEvent.swift:81)). The v5 route policy needs to fail fast and suppress automatic retries after a definitive pin mismatch.

- **MAJOR — Pairing persistence ordering is missing.** The phone must persist its identity and Mac pin before sending enrollment. If the Mac commits enrollment and the response is lost, the phone can simply redial with the same identity; rescanning should not be required. A temporarily locked pin store must not create a second identity.

- **MAJOR — Actual TLS integration tests are required.** Add real loopback `NWListener`/`NWConnection` tests for negotiated TLS 1.3, valid pins, wrong pins, provisional enrollment, plaintext downgrade rejection, concurrent ticket use, revoke/admit races, and reconnect after revocation with session caching.

## Minor findings

- **MINOR — “No bearer token on the wire” is inaccurate.** The enrollment ticket is a short-lived bearer. The accurate claim is “no durable bearer or session bearer.”
- **MINOR — Device labels are attacker-controlled.** Normalize control characters, cap bytes, avoid implying the label is trusted, and include a fingerprint suffix in notifications/list output.
- **MINOR — A root-owned file is not a viable alternative store for an unprivileged app.** If Keychain is rejected, the fallback is a user-owned protected file with an honest same-user integrity threat model.
- **MINOR — “Confidentiality is not required” overlooks device-name privacy and cross-host fingerprint correlation.**

## SS11 assessment

TLS 1.3, once implemented correctly, genuinely resolves the round-4 transcript-binding and active-relay substitution class. Mac-wide scope is server-authoritative; Iroh separation and sign-in scope match the live architecture.

SS11 is not yet fully carried forward: atomic single-use issuance, fail-closed randomness, immediate revocation, endpoint/transport migration, and old-client behavior remain unresolved. V5 also drops per-Mac compromise compartmentalization without acknowledging it.

No files were changed and no tests were run; this was a read-only design/source/API audit of HEAD `466131d518`.

CONSENSUS: BLOCKED - enrollment cannot occur under the stated unknown-key handshake rejection, the Curve25519 SecIdentity path is not executable as specified, legacy plaintext coexistence and ticket semantics conflict with v5, and revocation is not race-safe.

---

## Round 5 - Claude Response (v6)
**Timestamp:** (same session)

### Changes Made (v6) - all five blockers + all majors addressed
- B1: .enrollmentCandidate admission context (unknown cert accepted ONLY
  while an enrollment ticket is live; RPC surface = enroll only).
- B2: P-256 identities + swift-certificates as the named cert path; Phase 0
  hardware spikes gate the design; Noise-IK stays the documented fallback.
- B3: distinct enrollment-ticket type, CSPRNG-or-throw, coordinator actor
  with consume-after-persist (T3 Code atomic-consume pattern imported).
- B4: OPERATOR DECISION - zero external consumers, so no legacy: TLS-only,
  legacy pairing paths DELETED (bearer QR grammar, legacy private-network
  code, fallback heuristics) in a dedicated cleanup phase. No dual listener,
  no downgrade branches.
- B5: one actor owns table + admission + registry insertion; TLS session
  resumption disabled/revalidated.
- Majors: TLS parameter factories at construction seam; handshake-first
  admission restructure; ThisDeviceOnly accessibility + locked!=missing;
  per-pair phone identities (compartmentalization restored); full TLS
  profile pinned (1.3 only, peer_authentication_required, canonical SPKI
  fingerprint, ALPN cmux-devicelink/1); fail-fast pin mismatch; persist-
  before-enroll; loopback TLS integration test matrix mandated in Phase 1.
- Minors: bearer wording fixed; label hygiene + fingerprint suffix in
  notifications; file-store fallback framed honestly; name privacy noted.
- Comparator imports (T3 Code study): atomic consume, jittered backoff +
  foreground-resume bypass, discoverable-descriptor lesson noted via ALPN/
  versioning, QR-carries-the-capability principle retained.
- NEW: full implementation phasing (Phase 0 spikes -> package -> Mac -> iOS
  -> legacy deletion -> E2E) and the two-journey hardware matrix:
  iPhone 16 = fully automated devicectl journey, iPhone 17 = fully manual
  operator journey, M4 + M5, cross-matrix assertions.

---

## Round 6 - Codex Review
**Timestamp:** 2026-08-02T10:14:02Z

### Feedback

CONSENSUS: BLOCKED - the retained workspace-share ticket path has no valid admission model under the client-certificate-required TLS listener.

The paired-device path genuinely resolves round-5 B1–B3/B5 and the listed majors. Phase 0 appropriately gates the certificate/API assumptions.

Blocker:

- v6 requires every client to present a certificate on the TLS-only listener ([DESIGN.md](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:64)), but simultaneously retains workspace-share tickets “on their existing paths” ([DESIGN.md](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/plans/feat-account-free-reconnect/DESIGN.md:148)). Today those tickets select `.attachTicket` and reach the same TCP listener without any DeviceLink identity ([MobileCoreRPCClient.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:52), [CmxNetworkByteTransportFactory.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransportFactory.swift:58)). An unpaired share recipient therefore fails before presenting its bearer; a paired recipient already has Mac-wide admission, making workspace scope non-authoritative. Define a separate TLS share admission path, migrate shares to another authenticated transport, or explicitly remove Tailscale share links.

New-material corrections:

- The deletion inventory must explicitly partition device-pairing code from retained scoped-ticket code. In particular, account for the manual/synthetic attach path, `MobilePairingModel`’s Iroh/compatibility routing, Mac-wide ticket issuance, and temporary attach-ticket root authentication.
- Journey A revokes iPhone 16 from M5, but Journey B later expects and revokes the same row again. Specify reset/re-enrollment. A7 also should leave the M4-backed aggregate UI usable—not send the whole phone to the pairing sheet.
- The release-nightly automation commands are wrong: `CMUX_DOGFOOD_ATTACH_URL` is DEBUG-only, and Release registers `cmux-ios`, not `cmux-ios-dev` ([UITestConfig.swift](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/Packages/iOS/CmuxMobileSupport/Sources/CmuxMobileSupport/UITestConfig.swift:46), [Release.xcconfig](/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420/ios/Config/Release.xcconfig:18)). Release automation must use `openURL` with the actual `cmux-ios://` payload.
- Minor: the enrollment ticket is a short-lived bearer capability, so “QR carries no bearer credential” remains inaccurate. Also choose unconditional resumption disablement and verify the negotiated ALPN value rather than merely advertising it.

Read-only audit at HEAD `44ecfc7ff7d6`; no files changed or tests run.

---

## Round 6 - Claude Response (v7)
**Timestamp:** (same session)

### Changes Made (v7)
- BLOCKER resolved by extending the operator's zero-consumers ruling:
  Tailscale workspace-share links REMOVED. TCP listener = paired-device
  surface only; ephemeral cross-person sharing stays on Iroh (upstream,
  untouched). Flagged to operator for veto; consistent with their explicit
  "no legacy, delete redundant code" direction. Future account-free
  workspace sharing would return as a scoped enrollment, not a bearer path.
- Deletion inventory partitioned explicitly (deleted vs retained), now
  covering: manual/synthetic attach machinery (manual add-by-host survives
  as typed fingerprint+ticket payload), MobilePairingModel compatibility
  routing, mac-wide network ticket issuance, attach-ticket root auth.
- Journey A step 7 corrected (M5 revoke leaves M4 aggregate usable; no
  global pairing sheet) + new step 8 re-enrollment proving
  recovery-after-revoke and restoring fleet state for Journey B; B4
  sequencing made explicit.
- Release automation corrected: openURL with cmux-ios:// scheme;
  CMUX_DOGFOOD_ATTACH_URL documented as DEBUG-only iteration tooling.
- Minors: enrollment-ticket-is-a-short-lived-bearer wording fixed;
  resumption disablement made unconditional; client verifies negotiated
  ALPN.
- NEW operator directive recorded: package-first implementation for clean
  upstream merges; thin integration seams in fork-touched files;
  DeviceLinkKit + design to be offered to the team after delivery.

---
