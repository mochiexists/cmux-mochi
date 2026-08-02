# Account-free reconnect: a durable credential for the no-account path

**Status:** design, not started. For review by Codex before any code is written.
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

Net effect: no durable credential on either side.

---

## Proposed design

Mirror upstream's two-part shape, with a **long-lived attach ticket standing in
for the refresh token**. No new credential *type*, no new crypto — reuse the
ticket primitive that already exists, authorizes correctly, and is understood.

1. **Persist the Mac's ticket store.** Survives app restart. Keyed by auth token,
   same records, written somewhere appropriate for a secret (see Q3).
2. **Let a valid attach token authorize `attach_ticket.create`.** A ticket can
   mint its successor. This is the load-bearing change and the security-sensitive
   one.
3. **Issue a long-lived ticket at pairing.** `ttl_seconds` already supports any
   value; pairing issues e.g. 30 days instead of 1 hour.
4. **Phone stores it in the Keychain**, and on launch mints a fresh short-lived
   ticket from it, then connects. Roll the durable ticket periodically.
5. **Re-enable the reconnect path** for the no-account case
   (`shouldReconnectStoredMac` currently demands `stackAuthenticated`).

### Why not a brand-new device-credential type

Considered and rejected for round one: it duplicates ticket semantics
(scope, expiry, revocation, store) with a second code path to keep correct. If
review shows the long-ticket approach cannot be made safe, revisit.

---

## Questions for review — answer BEFORE implementing

> **Proposed answers (2026-08-02, verified against the code)** follow each
> question. Reviewer: challenge these, don't just nod.

1. **Self-extension.** Step 2 lets a bearer extend its own life indefinitely. Is
   that acceptable given the ticket is already tailnet-gated and Mac-scoped?
   Should a minted-from-ticket ticket be *weaker* than its parent (shorter TTL,
   no ability to mint again, narrower scope)?

   **Proposed:** copy the refresh/access split exactly, as a two-tier grant on
   the existing record. The durable ticket is **mint-only**: the only authorized
   method for it is `mobile.attach_ticket.create` (everything else returns
   `scopedTicketError`, same as today's `default:` arm in
   `MobileHostService+TicketAuthorization.swift`). Tickets it mints are today's
   ordinary short tickets — TTL capped at 1 h, **no mint grant**, scope inherited
   from the parent — so there is no grandchild chain. Durable→durable rotation IS
   allowed (that's how the credential stays fresh, see Q6) but rotation
   **invalidates the parent**, so at most one live durable ticket exists per
   pairing at any time.
2. **Revocation.** With tickets persisted, how does an operator revoke a lost
   phone? Today the store is memory-only, so quitting cmux revokes everything —
   persistence removes that property. Does the pairing UI need a device list?

   **Proposed:** round 1 ships CLI-grade revocation, UI later. (a) Persisted
   records carry issue date + a device label so they are recognizable. (b) New
   verbs `mobile.attach_ticket.list` / `mobile.attach_ticket.revoke`, exposed
   over the **local control socket only** (the path QR pairing already uses),
   never over the network listener. (c) Rotation auto-invalidates the previous
   durable ticket. Unpairing in the Mac UI purges the pairing's records.
3. **Storage.** Where does a persisted ticket store live on the Mac, given it
   holds bearer tokens? Keychain, or a file with correct permissions?

   **Proposed:** macOS Keychain, one generic-password item holding the
   serialized durable records (`MobileAttachTicketStore` already imports
   `Security` for `SecRandomCopyBytes`). Crucially, **only durable (mint-only)
   tickets are persisted** — short session tickets stay in-memory exactly as
   today, so a Mac restart still sheds every session credential and the phone
   quietly re-mints through the durable one. Smallest possible surface at rest.
4. **Blast radius of a 30-day ticket** vs the current 1 hour. Is a long TTL plus
   tailnet-pinning acceptable, or should the durable ticket be usable *only* for
   `attach_ticket.create` and nothing else — i.e. a mint-only scope?

   **Proposed:** mint-only, per Q1. A stolen durable ticket gets an attacker
   nothing except the ability to mint a session ticket **from inside the
   tailnet**, which is the same position a stolen 1 h ticket already grants;
   the difference is duration, which revocation (Q2) and rotation bound.
5. **Scope interaction.** Account-free Macs now live under
   `MobileLocalPairingScope` (`mochi-local:<uuid>`). Does the durable ticket key
   off that scope, and what happens to it when the user later signs in?

   **Proposed:** the phone keys the durable ticket in its Keychain by pairing id
   (`MobilePairedMac.pairingID`, i.e. macDeviceID + instanceTag) *within* the
   local scope. Signing in changes nothing: local-scope rows and account rows are
   already disjoint (`d8f17712c4`), so account pairings keep using Stack auth and
   local pairings keep using their durable ticket. No migration in round 1; a
   later "claim this Mac into my account" flow can re-key.
6. **Expiry while closed.** If the durable ticket lapses while the app is shut,
   the user must re-scan. Is a 30-day window enough, or should the phone refresh
   opportunistically in the background?

   **Proposed:** 30-day TTL, rotated opportunistically on every successful
   connect once the ticket is older than 24 h (cheap, no background task
   machinery, no BGTask unreliability). Effective contract: open the app at
   least once a month or re-scan. Acceptable for round 1.

---

## Test plan (must all pass before it ships)

**Unit**
- durable ticket mints a successor; expired durable ticket does not
- a minted-from-ticket ticket carries the intended (possibly reduced) scope
- persisted store round-trips across a Mac restart
- signing in does not let an account read the local scope's durable ticket, nor
  the reverse

**E2E on hardware — the point of the exercise**
1. Pair the phone to the **M5**, no account. Confirm connected.
2. **Force-quit the app. Cold launch.** Must reconnect with **no scan**.
3. **Restart cmux on the Mac.** Phone must reconnect once the Mac is back.
4. Pair the **M4** as well. Both Macs must stay connected — regression guard for
   the multi-Mac scope fix (`d8f17712c4`).
5. Screenshot showing **both** Macs' workspaces in one list, blue and green.
6. Leave it > 1 hour so the *short* ticket lapses; confirm the durable ticket
   silently mints a new one with no user action.

**Release**
7. Cut a nightly, install on M4 and M5, and repeat 1–6 against the **release**
   build — the interface pinning is `#if !DEBUG`, so DEBUG runs do not exercise it.

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
  port from a previous run.
- **`sync.subscribe_ok` / `liveness probe_ok` do NOT prove a Mac connection.**
  They are emitted by local sync setup regardless. Confirm on the Mac side.
- **Never open a cmux session or dev build in `/`** — it walks the filesystem and
  triggers macOS TCC prompts.

---

## Definition of done

- Cold launch reconnects with no scan, on the **release** nightly, on hardware.
- Both M4 and M5 connected simultaneously, screenshotted.
- Codex has reviewed the design (this doc) **and** the implementation diff.
- No regression in the 606 `CmuxMobileShell` tests.
