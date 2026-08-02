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
