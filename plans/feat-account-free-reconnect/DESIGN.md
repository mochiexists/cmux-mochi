# Account-free reconnect: a durable credential for the no-account path

**Status:** design v4, not started. Revised after Codex rounds 1–3
(see `DESIGN_review_history.md`); awaiting round-4 consensus.
**Branch:** `mochi/on-v0.64.20-wip`
**Author:** investigation 2026-08-01/02, verified against a real iPhone 16 + M4 + M5.

---

## The problem, stated precisely

A phone paired without an account **cannot reconnect after a cold launch**. Every
launch needs a fresh QR scan from the Mac.

This is not a bug in one function. The fork removed the durable half of a
two-part credential system and kept only the disposable half.

### How upstream works

| layer | lifetime | where it lives |
|---|---|---|
| Stack **refresh** token | durable, survives relaunch | phone Keychain (`KeychainStackTokenStore`) |
| Stack **access** token | ~1h, minted on demand | memory |
| **attach ticket** | ~1h, pruned server-side | Mac, in memory |

The attach ticket expires for everyone. Upstream does not care, because the phone
re-mints one whenever it needs to:

> "`mobile.attach_ticket.create` mints a bearer credential, so it MUST be
> authorized: a network caller has no attach token yet, so it is routed through
> the same-account Stack Auth token"
> — `Sources/Mobile/MobileHostService.swift:1623`

**The ticket is disposable. The Stack session is the durable thing.**

### Why the fork breaks

- `Packages/iOS/CmuxMobilePairedMac/.../MobilePairedMac.swift:6` —
  *"Auth tokens are never persisted, only enough to re-mint a fresh attach ticket"*
  The stored Mac keeps routes, not credentials.
- Re-minting needs `attach_ticket.create`, authorized by Stack auth. With no
  account there is nothing to present.
- `MobileRootAuthGate.shouldReconnectStoredMac` requires `stackAuthenticated`
  anyway, so the reconnect path is gated shut regardless.
- `Sources/Mobile/MobileAttachTicketStore.swift` is **in-memory only**
  (`recordsByAuthToken`), so tickets also do not survive a Mac restart.
- Even with a credential in hand, the reconnect loop never dials a stored raw
  Tailscale route — it treats one as a migration hint and fails with
  `.unsupportedRoute` (`MobileShellComposite.swift:1897–1968`). Route refresh
  comes from the authenticated account registry, which the no-account path
  does not have.

Net effect: no durable credential on either side, and no dialable route even if
there were one.

### Transport scoping (settled by review round 1)

Iroh admission requires a **backend-signed** credential — a pair-grant JWS or an
endpoint attestation proving a Stack account binding
(`CmxIrohAdmissionCredential.swift`). The account-free path has neither, so
**this feature is Tailscale-only by construction.** Consequences the design must
honor:

- Iroh-admitted connections bypass per-RPC ticket auth entirely
  (`MobileHostService.swift:1225` — `case .irohAdmission: return nil`). None of
  the new verbs may be reachable from an Iroh-admitted connection, and none of
  the new semantics claim to govern Iroh sessions.
- E2E tests must force the Tailscale transport explicitly, otherwise a test can
  "pass" through Iroh without exercising any of this.

---

## Proposed design (v2)

Two distinct credentials with distinct types and lifecycles. The QR ticket stays
exactly what it is today; a new **durable pairing grant** is issued *after* first
connect, over the already-authorized connection.

### 1. The QR ticket is unchanged

Short-lived (1 h cap as today, `TerminalController+MobileAttachTicket.swift:8`),
carried in the QR (`CmxPairingQRCode.swift` `k=` field), in-memory only,
session-scoped. A photographed QR remains a ≤1 h *acquisition* window — though
a registration within that window escalates durably; see §10 for the honest
statement of that accepted risk. Old iOS clients see no change at all.

### 2. Durable pairing grant, issued by registration

After the phone connects with a **mac-scoped** QR ticket, it calls a new verb:

- `mobile.pairing.grant.register` — authorized by the live mac-scoped attach
  ticket. Workspace-pinned tickets are refused (round 1 restriction).
  - Phone generates and persists, **before** sending: `{registration_id
    (random), an X25519 keypair (private key in the Keychain), state:
    pending}`. It sends `registration_id`, the **public key**, and a bounded
    device label (e.g. "Tim's iPhone 16", ≤64 chars).
  - Mac generates server-side: `grant_id`, `family_id`, a 32-byte secret `S`
    (CSPRNG, **throws if `SecRandomCopyBytes` fails** — no UUID fallback for
    grants), fixed 30-day TTL. No client-supplied TTL/scope/role is honored.
  - The response carries `S` **sealed to the phone's public key** (HPKE-style:
    CryptoKit ephemeral X25519 agreement + ChaCha20-Poly1305). The Mac
    persists the verifier `K = SHA-256(S)`, grant metadata (grant id, family
    id, device label, issue + expiry dates, pairing scope, client public key),
    and — per §5a — the **sealed blob itself** as replay material. The Mac
    never stores raw `S`, not even transiently: sealing happens before the
    commit, and what is committed is already opaque to everyone but the
    registering phone.
  - **Registration recovery survives a Mac restart and needs no QR ticket**:
    `mobile.pairing.grant.register_recover {registration_id}` returns the
    stored sealed blob + grant metadata. It is rate-limited, its unknown-id
    and throttled errors are indistinguishable, and its response is useless to
    anyone but the holder of the private key — possession of the persisted
    keypair *is* the authorization, which is exactly what an in-memory QR
    ticket could never provide across a restart.
  - Distinct `registration_id`s create distinct grants (that is what multiple
    phones scanning one QR look like), capped at 4 registrations per QR
    ticket on top of the global grant quota. Retrying the same
    `registration_id` never consumes quota twice.
  - The Mac posts a **user notification** on every successful registration
    ("iPhone 'Tim's iPhone 16' is now durably paired — manage with
    `cmux rpc mobile.pairing.grant.list`"), so a covert registration by a QR
    photographer is at least visible on the Mac it targets (§10).

This is a distinct typed role with its own DTO — **not** a `CmxAttachTicket`
with a long TTL. Review round 1 established that overloading the ticket type is
unsafe (no phone identity, no family, QR leakage, old-client confusion).

### 3. The grant is mint-only, and children are server-derived

The phone never sends the raw secret `S` over the wire. Grant-authorized verbs
are authorized by the challenge-response proof of §7a, which demonstrates
possession of `K = SHA-256(S)` without disclosing it. Exactly two verbs accept
a grant proof, both new, both network-path:

- `mobile.pairing.grant.mint_session` — issues an ordinary short-lived session
  ticket: TTL fixed server-side at 1 h, **mac scope copied from the grant
  record**, no mint capability, in-memory only, same
  `MobileAttachTicketStore` record shape as today. The handler derives
  everything from the authenticated grant; it ignores `ttl_seconds`, `scope`,
  and route/target parameters (`TerminalController+MobileAttachTicket.swift`'s
  parameter-trusting path is never reachable from a grant).
- `mobile.pairing.grant.rotate` — idempotent rotation, below.

A grant authorizes **nothing else**: every other method returns
`scopedTicketError`, enforced in the same single-lookup authorization path as
today (`MobileHostService+TicketAuthorization.swift`). Session tickets minted
from a grant carry no mint grant, so there is no grandchild chain.

### 4. Idempotent rotation (lost-response-safe)

Naive rotate-and-invalidate strands the phone when the response is lost or iOS
crashes before its Keychain write. Protocol instead:

1. Phone persists `{rotation_id (random), a fresh X25519 keypair, state:
   pending}` **before** sending `rotate {rotation_id, client_pubkey}`.
2. Mac, atomically within the store mutation: revalidate the grant, mint the
   successor, seal it to `client_pubkey`, persist `parent_verifier +
   rotation_id → sealed successor` in one commit — **the sealed replay
   material (§5a) is what makes the commit survive a Mac restart.**
   Persistence failure leaves the parent untouched and returns an error.
3. **Retrying the same `rotation_id` returns the identical raw successor**,
   even across a Mac restart between commit and retry (that is precisely what
   §5a exists for). A spent parent is otherwise unusable (mint_session and
   fresh rotations fail).
4. Phone atomically replaces its Keychain record on response, then clears the
   pending marker.
5. At most one live grant per family. Concurrent rotations with different
   `rotation_id`s: first commit wins; the loser gets the committed successor
   replay only if it presents the winning `rotation_id`, else an error that
   tells the phone to retry with its stored pending id.

Rotation cadence: on each successful connect, if the grant is older than 24 h.
No background refresh machinery (BGTask unreliability) — the contract is "open
the app at least once every 30 days or re-scan."

**Absolute lifetime: none — intentionally.** A grant in active use renews
indefinitely, like any refresh token. This is a dogfood fork whose threat model
assumes tailnet membership is controlled; documented here so it is a decision,
not an accident.

### 5a. Replay material: how idempotency survives a restart

A verifier (`K`) cannot reproduce the raw secret it verifies, so an
acknowledged-response protocol needs **recoverable replay material** for the
window between commit and acknowledgment. The client keypair (§2) makes this
clean:

- Every secret-issuing request (`register`, `rotate`) carries a fresh client
  X25519 public key. The Mac seals the new secret to that key **before** the
  commit; the committed replay material is the **sealed blob**, never raw
  `S`. The Mac holds nothing a thief of its Keychain could use to *become*
  the phone's grant — at rest there are only verifiers and blobs decryptable
  solely by the phone.
- Recovery (`register_recover` / `rotate_recover`, keyed by
  `registration_id`/`rotation_id`) returns the sealed blob. It requires no
  other live credential — after a Mac restart, possession of the persisted
  client private key is what turns the blob back into a grant, and without it
  the response is noise. Rate-limited; unknown-id and throttled errors
  indistinguishable.
- The replay material is **erased at first use** of the new grant (its first
  successful challenge-response proof is possession evidence — the phone
  provably received it) or after a 48-hour retention window, whichever comes
  first. After erasure, the record is verifier-only and the recovery path for
  that id returns a terminal "re-pair required" error instead of a replay.
- Pruning of replay material happens on load and on every mutation, same as
  expiry pruning.

### 5. Persistence on the Mac

- A dedicated repository (actor) owning grant records; the existing
  `MobileAttachTicketStore` stays in-memory for session tickets. **No Keychain
  I/O inside the existing `NSLock`** — the store's lock guards memory, the
  repository serializes disk.
- Storage: macOS Keychain, one generic-password item holding the serialized
  grant table. Service name namespaced per bundle id **and instance tag**
  (Stable/Nightly/tagged dev builds share a physical Mac; two tagged apps must
  never load each other's grants — `MobileHostIdentity.swift`).
- Schema: versioned envelope `{version: 1, grants: [...]}`. Unknown version or
  corrupt payload → treated as empty (all phones re-pair), logged loudly, never
  a crash. Expired grants pruned on load and on every mutation.
- Ordering: persist first, then publish to memory / return success.
- Loaded before the network listener reports ready (initialization barrier), so
  a phone can't race a cold Mac into "unknown grant".
- Quotas: ≤16 grants per Mac; ≤4 live session tickets per family (oldest
  evicted); rotation throttled to 1/min per family; global session-record cap
  as today via TTL pruning.

### 6. Revocation

- New verbs `mobile.pairing.grant.list` / `mobile.pairing.grant.revoke`,
  exposed **only over the local control socket** (`TerminalController` v2 path,
  same placement as QR minting). They must not appear in
  `mobileHostHandleRPC`'s network dispatch — and therefore are unreachable from
  Iroh-admitted or ticket-authorized network callers. A test asserts exactly
  this.
- `revoke` kills the **family**: the grant, every session ticket it minted
  (session records gain a `family_id`), and every live connection bound to the
  family. The connection registry currently tags ticket-authorized TCP
  connections `.stackBearer` (`MobileHostService.swift:1123`); it gains a
  family binding so family revocation can close them. Until a connection's
  family is identifiable, revoke falls back to closing all `.stackBearer`
  connections — crude but fail-safe.
- Rotation auto-invalidates the parent (modulo the committed-replay window).
- Round 1 ships CLI-grade revocation (`cmux rpc mobile.pairing.grant.list`,
  `... .revoke '{"grant_id":"…"}'`). A pairing-UI device list is future work —
  the Mac UI currently has no per-phone surface at all, only connection counts,
  so the earlier claim that "unpairing in the Mac UI purges records" is
  withdrawn.

### 7. Phone-side storage and reconnect

- Grant stored in the iOS Keychain keyed by pairing id
  (`MobilePairedMac.pairingID` = macDeviceID + instanceTag) within the local
  scope. `kSecAttrAccessibleAfterFirstUnlock` so a background relaunch can
  read it.
- `shouldReconnectStoredMac` (`MobileRootAuthGate.swift:84`) does **not**
  simply drop `stackAuthenticated`; it gains an explicit
  `hasUsableDurableCredential` input. Missing, expired, corrupt, or
  Keychain-inaccessible grant state ⇒ `false` ⇒ clean fall-through to the
  pairing sheet, never a spin.
- Reconnect flow, account-free branch: dial last-known Tailscale route in
  `.attachTicket` transport mode using a synthetic probe ticket — the exact
  mechanism today's manual-host flow uses
  (`MobileShellComposite+ManualAttachTicket.swift:102`,
  `syntheticManualHostTicket`), which is what the Tailscale transport factory
  accepts (`CmxNetworkByteTransportFactory.swift:51`) — then run the §7a
  handshake → `mint_session` → attach with the fresh session ticket →
  opportunistic rotate (§4). Note the unauthenticated `mobile.host.status`
  probe deliberately withholds identity (`MobileHostService.swift:320`) and a
  self-reported identity would authenticate nothing anyway; §7a is the
  authentication.

### 7a. Grant reconnect handshake (mutual challenge-response)

The raw grant must never be disclosed to an impostor squatting on the Mac's
port. Neither side trusts the transport (Network.framework cannot prove the
packet tunnel is Tailscale — `CmxByteTransportRequest.swift:10`), so
authentication is cryptographic, both ways, before anything grant-derived is
sent:

1. Phone → Mac: `mobile.pairing.grant.challenge {grant_id, phone_nonce}`.
   Unauthenticated verb, rate-limited; unknown `grant_id` and throttled
   requests return one indistinguishable generic error (no existence oracle).
2. Mac → phone: `{mac_nonce, mac_proof = HMAC-SHA256(K, "mac-proof" ‖
   phone_nonce ‖ mac_nonce)}`. The Mac proves possession of `K` without
   revealing it. An impostor cannot produce this; the phone verifies (it
   derives `K` from `S`) and **aborts before presenting anything** on
   mismatch — falling to the re-scan prompt, never a hang.
3. Phone → Mac: the grant-authorized call (`mint_session` or `rotate`)
   carrying `phone_proof = HMAC-SHA256(K, "phone-proof" ‖ mac_nonce ‖
   phone_nonce)`. Proofs are bound to both single-use nonces (small in-memory
   nonce table, short expiry), so neither proof replays.
4. Every secret a response carries — a rotation/registration successor, and
   the **`mint_session` session ticket bearer too** — is sealed to a fresh
   client X25519 public key sent with the request (§5a mechanism, uniformly).
   A passive on-path observer inside the tailnet learns nothing usable.

**What the handshake does and does not claim (round-3 finding, scoped
honestly).** The proofs authenticate endpoints and the sealing defeats passive
capture, but an *active relay* — realistically, an unprivileged process on the
Mac squatting the preferred port and forwarding to the real listener — sits
inside the phone's session once established: subsequent requests carry the
session bearer as plaintext `attach_token` JSON
(`MobileCoreRPCClient.swift:396`), so a relay can capture **session-tier**
credentials (≤1 h, revocable with the family). This is *exactly* the exposure
today's QR flow already has — a port-squatter during pairing captures the QR
ticket bearer the same way — so this feature leaves session-tier relay risk
unchanged while guaranteeing one new thing: **the durable credential never
transits in a capturable form** (`S` only ever moves sealed; proofs are
nonce-bound HMACs). Accepted for round 1 and stated in §10. The upgrade path
if the threat model hardens: pin a Mac TLS identity at registration and run
the RPC channel over it, or switch grant-minted sessions from bearer tokens to
per-request HMAC under a sealed session key — both deliberately out of scope
now.

Also accepted and documented: an attacker who reads the Mac's Keychain holds
`K` and can impersonate either side of this handshake — but that attacker owns
the Mac already. Raw `S` never rests on the Mac at all (§5a stores only sealed
blobs).

### 8. Endpoint discovery without an account

The account path refreshes routes from cloud backup; account-free has no
authority to ask. Round-1 answer, explicitly modest:

- The Mac **persists the port it successfully bound** (per instance tag) and
  prefers rebinding it on relaunch, falling back to ephemeral only when taken
  (then persisting the new one). Tailscale node IPs are already stable, so in
  steady state the stored route stays valid across Mac restarts.
- The phone tries the stored route; on identity mismatch or timeout it also
  probes the instance's preferred port. Both failing ⇒ surface "scan to
  reconnect". No port scanning, no broadcast discovery in round 1.
- Residual gap, accepted and documented: if another process steals the
  preferred port during the exact restart window, the phone needs one manual
  re-scan. E2E covers the steal-and-restart case to prove the failure is the
  documented one (re-scan prompt), not a hang.

### 9. Scope interaction with sign-in (corrected)

The earlier claim that "signing in changes nothing" was wrong. The code chooses
the Stack user over the local scope and explicitly invalidates a local scope
after sign-in (`MobileShellComposite+Scope.swift:16,61`). **Adopted behavior:
local pairings disappear while signed in, reappear on sign-out.** Grants keep
working after sign-out because they live under the local scope key, untouched
by account sessions. Tested: no-account pair → sign in → relaunch → sign out →
reconnect without re-scan. A later "claim this Mac into my account" migration
is out of scope.

### 10. Threat model, stated honestly

A stolen grant is **not** "nothing but minting": minting yields a mac-scoped
session ticket, i.e. full terminal access on that Mac — same power as today's
stolen 1 h ticket, for longer. Bounds: usable only from inside the tailnet;
the Mac stores only verifiers and phone-sealed blobs (raw `S` never rests
there); revocable per family; rotation means a thief racing the owner locks
one of them out, which is at least *visible* (the owner's next rotate fails
against an unknown grant → the phone surfaces "re-pair needed" and the Mac
logs a security event).

**Active-relay exposure is session-tier only and pre-existing** (§7a): a
port-squatting relay can capture a ≤1 h session bearer — as it can during
today's QR pairing — but never the durable grant. Accepted; upgrade paths
noted in §7a.

**QR escalation, stated honestly (round-2 finding):** the QR's *acquisition*
window is ≤1 h, but a photographer who registers within that window obtains an
indefinitely renewable family — the compromise itself is not one-hour-bounded.
This is **accepted** for this dogfood fork, with mitigations rather than
prevention: every registration fires a visible Mac notification naming the
device label (§2), `grant.list` shows all families with labels and issue
dates, and `grant.revoke` kills one family without disturbing the others.
Prevention (per-registration local approval on the Mac) is deliberately
deferred — it reintroduces the tap-on-Mac friction this feature exists to
remove — and is the first thing to revisit if the threat model hardens.

---

## Questions from v1 — resolved

| # | Question | Resolution |
|---|---|---|
| 1 | Self-extension | Grants rotate (idempotent, §4); session children are strictly weaker (1 h, no mint). No grandchild chains. |
| 2 | Revocation | Family-wide revoke via local-socket-only verbs; CLI round 1, UI later (§6). |
| 3 | Storage | Mac Keychain digest-at-rest via repository actor (§5); phone Keychain for the raw grant (§7). |
| 4 | Blast radius | Mint-only grant, server-derived children (§3); honest threat wording (§10). |
| 5 | Scope on sign-in | Local pairings hidden while signed in — matches code, now documented + tested (§9). |
| 6 | Expiry while closed | 30-day TTL, rotate-on-connect after 24 h, no background refresh (§4). |

---

## Test plan (must all pass before it ships)

**Unit — credential lifecycle**
- grant mints a session ticket; expired/revoked/spent grant does not
- minted session ticket: 1 h TTL, grant's mac scope, no mint capability; a
  session ticket presented to `mint_session`/`rotate` fails
- `register` refused for workspace-pinned tickets, Iroh-admitted connections,
  and unauthenticated callers; label length enforced
- scope/TTL/route/role parameter overrides are ignored on every grant verb
- rotation: lost response then retry with same `rotation_id` returns the same
  successor; different `rotation_id` against a spent parent fails; concurrent
  rotations leave exactly one live grant; persistence failure leaves the
  parent valid
- **commit → lose response → restart Mac (reload from Keychain) →
  `rotate_recover`/`register_recover` with the same id → identical sealed
  successor, decryptable by the persisted client private key, with no QR
  ticket or parent credential presented** (§5a)
- replay material: erased at successor's first use and at the 48 h window;
  post-erasure recovery returns the terminal re-pair error, not a replay
- registration idempotency: retried `registration_id` returns the same grant
  and never consumes quota twice; per-QR-ticket registration cap enforced
- sealing: raw `S` appears nowhere in the Mac's store or on the wire (assert
  on the serialized table and a wire capture); a blob sealed to one keypair
  does not decrypt with another; `mint_session`'s bearer is sealed to the
  request's client pubkey
- handshake (§7a): phone aborts on bad/missing `mac_proof` before sending
  anything grant-derived (spoofed port-owner test); nonces are single-use
  (replayed proofs fail); unknown `grant_id`/`registration_id` and
  rate-limited responses are indistinguishable
- phone crash between response and Keychain write: pending marker + retry
  recovers
- CSPRNG failure ⇒ grant creation throws (no UUID fallback)

**Unit — persistence and store**
- grant table round-trips across a simulated Mac restart; session tickets do not
- corrupt / unknown-version payload ⇒ empty table, no crash
- tagged-app namespace isolation: two service names never read each other
- quotas: grant cap, per-family session cap, rotation throttle
- family revoke kills grant + minted sessions + bound connections;
  `.stackBearer` fallback path covered
- `list`/`revoke` absent from network dispatch (explicit test), present on the
  control socket
- initialization barrier: no "unknown grant" window on cold start

**Unit — phone gating and scope**
- `shouldReconnectStoredMac` with `hasUsableDurableCredential` truth table,
  including corrupt/inaccessible Keychain ⇒ pairing sheet
- local → signed-in → local transitions (§9), including a Mac present in both
  scopes
- signing in cannot read the local scope's grant, nor the reverse

**E2E on hardware — the point of the exercise** (force Tailscale transport)
1. Pair the phone to the **M5**, no account. Confirm connected.
2. **Force-quit the app. Cold launch.** Must reconnect with **no scan**.
3. **Restart cmux on the Mac.** Phone must reconnect once the Mac is back
   (stable-port rebind, §8).
4. Port-steal case: occupy the preferred port, restart cmux (ephemeral
   fallback), confirm the phone surfaces the re-scan prompt rather than
   hanging.
5. Pair the **M4** as well. Both Macs must stay connected — regression guard
   for the multi-Mac scope fix (`d8f17712c4`).
6. Screenshot showing **both** Macs' workspaces in one list, blue and green.
7. Two phones scan one QR: both register, distinct grants/labels, rotating one
   never breaks the other; each registration fires the Mac notification.
8. Leave it > 1 hour so the session ticket lapses; confirm the grant silently
   mints a new one with no user action.
9. Revoke the grant family from the Mac CLI mid-session: connection closes,
   phone falls to the pairing sheet.
10. Old-client sanity: a build predating the grant verbs pairs and runs
    exactly as today.

**Suites**: not just the 606 `CmuxMobileShell` tests — also host
authorization/store, MobileRPC, MobileTransport, MobileWorkspace,
control-socket, and Iroh suites. Regression tests follow the repo's two-commit
red/green policy.

**Release**
- Cut a nightly, install on M4 and M5, and repeat the E2E list against the
  **release** build — the interface pinning is `#if !DEBUG`, so DEBUG runs do
  not exercise it.

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

- **`lsof` cannot see these connections.** Tailscale's userspace networking means
  accepted sockets are not attributed to the app's pid. Use
  `netstat -an | grep <port>`. This cost a full debugging cycle.
- **`strings` in the binary does not prove a string is shown.** `L10n.string`
  resolves the `.xcstrings` catalog first; the `defaultValue` is a fallback.
  Edit the catalog too.
- **The Mac's pairing port changes on every launch** when another cmux instance
  holds the preferred port (ephemeral fallback). Always re-mint; never reuse a
  port from a previous run. (§8 makes the port sticky for account-free hosts —
  after that lands, the trap softens but the steal case remains.)
- **`sync.subscribe_ok` / `liveness probe_ok` do NOT prove a Mac connection.**
  They are emitted by local sync setup regardless. Confirm on the Mac side.
- **Never open a cmux session or dev build in `/`** — it walks the filesystem and
  triggers macOS TCC prompts.

### Stale contracts to update alongside the code

- `MobilePairedMac.swift:4` ("Auth tokens are never persisted") — grants are
  persisted on the phone now; reword.
- `MobileAttachTicketStore.swift` header comments asserting tickets are the
  only credential.
- `CmxPairingQRCode.swift` "keep TTLs short" comment — still true, now
  load-bearing; reference this design.

---

## Definition of done

- Cold launch reconnects with no scan, on the **release** nightly, on hardware.
- Both M4 and M5 connected simultaneously, screenshotted.
- Codex has reviewed the design (this doc) **and** the implementation diff.
- Full suite list above green, red/green regression commits included.
