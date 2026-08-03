# Review brief — simulator reconnect + "both Macs not listed on iPhone 17"

Repo: `/Users/timapple/Documents/mochi/mochi-dev/cmux-mochi-v06420`
Branch: `mochi/on-v0.64.20-wip`, HEAD `099b69d90e`.

Read-only review. Answer with `file:line` and severity (BLOCKER / MAJOR / MINOR).

## Context in one paragraph

This fork adds **DeviceLink**: account-free phone↔Mac pairing. Per-device P-256
keypair, self-signed X.509, SPKI SHA-256 fingerprint pinned both ways, mutual
TLS 1.3, ALPN `cmux-devicelink/1`. The Mac publishes routes (numeric tailnet
v4/v6 + MagicDNS `*.ts.net`). The phone stores, per paired Mac, a
`mac_device_id` row plus a keychain identity and pin keyed by `pairing_id`.
On cold launch the phone re-dials stored Macs with no QR rescan.

## Question 1 — why does the SIMULATOR never reconnect?

Physical iPhones 16 and 17 pair and cold-launch reconnect fine against the same
Mac build. The **simulator pairs fine** (`enrolled ok via 127.0.0.1:<port>`,
`persisted=true`) but **never reconnects**.

Symptom on cold launch:

```
reconnect gate ... pairedDevice=true
reconnect scope signedIn=true resolved=mochi-local:<uuid>
dial decision mac=24D04160… routes=debug_loopback,tailscale,tailscale,tailscale
              credential=true canConnect=true
dial candidates: 127.0.0.1:58525 100.112.69.84:58525 fd7a:115c:a1e0::e53a:4555:58525 timapple-m5.tailfc3a5b.ts.net:58525
tls options: offering devicelink:8dd06915fb28a for target 24D04160-6D4
transport asked for TLS options: provided      ← ONLY 3 of these, for 4 candidates
   … ×3, each ~8.4 s apart
dial finished: failed(unknown)
```

Mac side, same window: `rejected connection: handshake failed —
connectionFailed("Network connection failed.", CmxConnectFailureKind.timedOut)` ×2.

### Already ELIMINATED — do not re-derive

1. Wrong pin offered. Log shows the correct single pin.
2. Loopback excluded from candidates. It is listed **first** in `dial candidates`.
3. `CmxLoopbackHost().matches` rejecting the route — covered by a passing test.
4. Mac not listening. `nc -vz 127.0.0.1 <port>` succeeds; Mac logs arriving conns.
5. Stale port after the per-tag port change. Re-paired and reproduced.
6. `sec_identity_create` returning nil — a log for exactly that case never fires.
7. Client TLS verify block never runs (`DeviceLinkTLS.verificationObserver`
   produces no output), and the **Mac's** verify/admit line is also absent. So
   the handshake never starts; it is not a pinning or admission decision.

### The live lead, and what I want checked

`CmxNetworkByteTransportFactory.makeTransport(for:)` (Packages/iOS/CmuxMobileTransport/…)
has a `.debugLoopback` branch that passes `tlsOptions: deviceLinkTLSOptions?()`
— i.e. **optional**, so a nil closure silently yields a PLAINTEXT transport
against a TLS-only listener. The `.tailscale` branch by contrast fails closed
(`guard let tlsOptions = deviceLinkTLSOptions?() else { throw }`).

`CmxNetworkRoutePinger.init()` (same package) constructs
`CmxNetworkByteTransportFactory()` with **no** `deviceLinkTLSOptions` and dials
with `authorizationMode: .stackBearer`. For `.debugLoopback` that passes the
auth guard and produces a plaintext dial.

Please answer:

1. Is the pinger's plaintext loopback dial the source of the Mac-side handshake
   timeouts (rather than the reconnect dial)? Does that fully explain
   "3 TLS-option requests for 4 candidates"?
2. Should `.debugLoopback` fail closed like `.tailscale`? What breaks — the
   UI-test mock host is the reason the optional exists.
3. Is there any path where the loopback candidate is dialled WITHOUT reaching
   `makeTransport(for: request)` at all (a cached/short-circuit transport, a
   different factory registration, an early-return in the candidate loop)?
   That is the remaining unexplained fact.
4. Anything about the **simulator specifically** — keychain identity whose
   private key is not usable for signing, `sec_identity_create` behaviour,
   Network.framework loopback + TLS on the simulator — that would make the
   handshake stall rather than fail?

## Question 2 — the phone shows no Macs even when connected

Fixed once already, at `Packages/iOS/CmuxMobileShellUI/…/MobileRootAuthGate+ShellSync.swift`:
`syncShellAuthentication` called `store.signOut()` on every unauthenticated
Stack auth sync. A DeviceLink pairing is permanently unauthenticated in Stack
terms, so it fired ~49 s after every successful reconnect. Paired Macs are
looked up **by scope**, scope resolution requires a signed-in shell, so the
store returned nothing → "no computers paired" while a connection was live.
Now guarded on `MobileDeviceLinkClient.shared.hasAnyPairedDevice()`.

**The user reports the iPhone 17 still does not list both Macs.** The 17 has
pairings to the M4 and the M5; the 16 works.

Please audit the whole paired-Mac read path for OTHER places the same family of
bug survives — an account/scope precondition gating an account-free credential:

- `MobileShellComposite+PairedMacPersistence.swift` (load + upsert; note the
  build-compatibility wrapper **silently drops** writes whose build tag does not
  match exactly)
- `MobileShellComposite+Scope.swift` (scope resolution preconditions)
- `MobileMacBuildCompatibilityPolicy` / `MobileIOSBuildScope` — the phone and
  Mac must share a build tag; a tagged Mac + untagged phone drops writes
  silently. **Could two Macs on DIFFERENT build tags mean only one row is ever
  readable?** This is my leading suspicion for question 2.
- Any list/menu view that filters paired Macs by account, team, or scope.

Rank by likelihood that it explains "the 17 shows neither Mac".

## Question 3 — delete and re-pair

`MobileDeviceLinkClient.forget(pairingID:)` removes the pin, the identity, and
the keychain items. Please check the **whole** unpair path for leftovers that
would make a subsequent QR re-pair fail or silently reuse stale state:

- Is the `paired_macs` row deleted, and is `pairingIDsByMacDeviceID`
  (UserDefaults key `devicelink.pairingIDsByMacDeviceID`) pruned?
- Is `activeDialTarget` cleared?
- Does the **Mac** forget its side, or does it still admit the old fingerprint?
- After forgetting the last Mac, `hasAnyPairedDevice()` goes false — does the
  auth-sync guard above then sign the shell out and strip scope mid-flow,
  breaking the immediately following re-pair?

End your review by naming your 3 least-confident areas.
