# Simulator reconnect: what is proven, what is not

Written 2026-08-03 so the next session does not re-derive any of this.

## Status

| Journey | Result |
|---|---|
| iPhone 16 (physical) ↔ M5, pair | **passing** |
| iPhone 16 (physical) ↔ M5, cold-launch reconnect, no rescan | **passing**, repeatedly |
| Simulator ↔ M5, pair | **passing** (`enrolled ok via 127.0.0.1:<port>`, `persisted=true`) |
| Simulator ↔ M5, cold-launch reconnect | **FAILING** — see below |
| iPhone 16 ↔ M4 | not started; M4 has no build of this branch yet |
| iPhone 17 manual QR | not started |

The simulator failure is **simulator-specific**. The physical iPhone 16 was
re-tested immediately afterwards on the same Mac build and reconnected fine, so
this is not a regression in the reconnect path itself.

## The simulator symptom, precisely

On cold launch the phone side does everything right up to the dial:

```
reconnect gate ... pairedDevice=true
reconnect scope signedIn=true resolved=mochi-local:<uuid>
dial decision mac=24D04160… routes=debug_loopback,tailscale,tailscale,tailscale
              credential=true canConnect=true
dialing stored mac 24D04160…
tls options: offering devicelink:8dd06915fb28a of 1 pin(s)   ← correct pin, only one
transport asked for TLS options: provided
   … ×3, each ~8.4 s apart
dial finished: failed(unknown)
```

Mac side, same window:

```
rejected connection: handshake failed —
  connectionFailed("Network connection failed.", CmxConnectFailureKind.timedOut)   ×2
```

## Hypotheses tested and ELIMINATED

Do not retry these; each was checked against evidence.

1. **Wrong pin offered (multi-Mac pin selection).** Eliminated. The log shows
   `of 1 pin(s)` and the offered pairing `devicelink:8dd06915fb28a` matches the
   Mac's fingerprint from the pairing code. There is only one pin on this device.
2. **Loopback excluded from reconnect candidates.** Eliminated.
   `prefersNonLoopbackRoutes` is `false` on the simulator
   (`MobileShellComposite.swift:2634`), so the loopback-excluding branch of
   `reconnectHostPortRoutes` is not taken, and `supportedKinds` on the simulator
   includes `.debugLoopback` (`ios/cmux/cmuxApp.swift:38`).
3. **`CmxLoopbackHost().matches` rejecting the stored route.** Unlikely —
   `CmxLoopbackHostTests.classifiesRoutesByKindAndHost` proves it matches a
   `.debugLoopback` route by kind.
4. **Mac not listening / unreachable.** Eliminated. `nc -vz 127.0.0.1 <port>`
   succeeds, and the Mac logs accepted-then-timed-out connections during the
   window, so connections do arrive.
5. **Stale port after the per-tag port change.** Eliminated by re-pairing the
   simulator against the new port and reproducing the failure.

---

# RESOLVED 2026-08-04 — root cause found

Everything below this heading up to "## Fix already made" is **superseded**.
Kept because the eliminations are still valid and re-deriving them costs a day.

**The loopback candidate was never dialled at all.**

`manualHostTicket` mints an attach ticket when `routeAllowsStackAuth(route)` —
which admits **loopback and nothing else**. Minting needs a Stack access token,
and `requestDataWithAuth` fetches it *before* `session.send` builds the
transport. An account-free device has no token, so the loopback candidate threw
before a socket was opened.

That accounts for every number exactly:

| Observation | Explanation |
|---|---|
| 4 candidates, 3 `asked for TLS options` | loopback failed pre-transport; the 3 tailnet routes each built one |
| verify block never ran, on **either** side | no TLS handshake ever started |
| ~8.4 s spacing | the 8 s pairing-RPC deadline, dialling tailnet addresses the Mac cannot reach from itself |
| 2 Mac-side handshake timeouts vs 3 dials | those were not from the simulator — a bare `nc` connect that sends no ClientHello logs identically |
| hardware unaffected | `prefersNonLoopbackRoutes` is true on device, so phones never enter this path |

Found independently by Fable and by Codex (gpt-5.6-sol, high), which agreed on
the file, the mechanism and the fix. Fixed in `c66e7a4758`: a DeviceLink dial
takes the synthetic ticket, because it authorises with the device's own key and
needs no minted ticket.

**Status: fixed in code with a regression test; NOT yet verified end-to-end on a
simulator.** The headless pairing harness (mint via the local socket, deliver by
`simctl openurl`) did not get the app to log a URL arrival, so the e2e proof is
still owed.

## The live lead (superseded — see above)

**The client TLS verify block never executes.** `DeviceLinkTLS.verificationObserver`
was added and wired into the device log; across three dials it produced no
output at all, while `sec_protocol_options_set_verify_block` is definitely
installed on those options. So the handshake stalls *before* the client
validates the server certificate, and both ends then time out.

That points at the handshake never starting properly rather than at any
admission or pinning decision. Next things to check, in order:

1. ~~`sec_identity_create(identity)` returning nil~~ — **ELIMINATED**. A log was
   added for exactly that case and it never fires, so the client certificate is
   attached.
2. **Log the host:port actually dialled.** This is now the decisive missing
   fact and the single next thing to do. Every existing log line says *that* a
   dial happened, none says *where to*. Without it we cannot tell whether the
   three attempts are the three tailnet routes (which the Mac cannot reach from
   itself — `nc` to its own tailnet IP fails, so these would time out exactly
   like this) or whether loopback is genuinely being dialled and failing. The
   ~8.4 s spacing looks like a TCP connect timeout, which fits "dialling the
   unreachable tailnet addresses and never trying loopback" far better than it
   fits a TLS failure over loopback.

   If that is what is happening, the two Mac-side handshake timeouts are NOT
   from the simulator, and the real bug is route *selection*, not TLS. Confirm
   by correlating counts: 3 dials vs 2 Mac-side rejections already do not match.
3. Whether the simulator keychain returns an identity whose private key is not
   usable for signing (simulator keychain differs from device).

## Fix already made while investigating

`DeviceLinkTLS.verificationQueue` was **serial**, shared by the listener and
connection verify blocks. One slow or non-completing verify block would stall
every other handshake in that process behind it. It is now `.concurrent`;
verification is pure (hash a cert, compare to a snapshot), so there is nothing
to serialize for correctness. This did not fix the simulator, but it was a real
latent bug.

## Note for multi-Mac (up to ~5)

`MobileDeviceLinkClient.currentPairingTLSOptions()` picks the **first** pin in
sorted order and has no idea which Mac is being dialled. With one paired Mac it
is correct by luck. With several it will offer the wrong identity and the dial
will die in the handshake — indistinguishable from an unreachable Mac.

The structural gap: `paired_macs` stores `mac_device_id` but **no fingerprint**,
so a stored Mac cannot be mapped to its pin. Fixing multi-Mac properly needs
either a fingerprint column (or a local `mac_device_id → pairing_id` map) plus a
target-aware TLS-options closure — the transport factory's closure is currently
zero-argument (`CmxNetworkByteTransportFactory.swift:16`) and would need the
route passed in.

This is required before a phone can hold pairings to both the M4 and the M5.

---

# iPhone 17: reconnect works, then the session is signed out

Proven on hardware 2026-08-03. **Journey B passes**: cold launch → `dial
finished: connected` in 0.75 s with no rescan.

```
[0.430] dial decision mac=24D04160… credential=true canConnect=true
[0.435] tls options: offering devicelink:8dd06915fb28a for target 24D04160-6D4
[0.563] client verify: server 8dd06915fb28 expected 8dd06915fb28 -> accept
[0.748] dial finished: connected
[49.5]  reconnect scope signedIn=false requested=nil resolved=nil   ← regressed
[182.7] reconnect scope signedIn=false requested=nil resolved=nil
```

## Root cause

`MobileShellComposite.signOut()` (MobileShellComposite.swift:1108) sets
`isSignedIn = false`, and its own comment records that it "is called on every
unauthenticated auth-state sync". An account-free DeviceLink pairing is
permanently unauthenticated in Stack terms — that is the entire point — so every
sync signs the shell out.

Paired Macs are looked up **by scope**, and scope resolution requires a
signed-in shell (`MobileShellComposite+Scope.swift`). Once `isSignedIn` is false
the scope resolves to `nil` and the store returns nothing, so the UI reports "no
computers paired" while the DeviceLink connection is still live. The legacy
attach panel separately shows "Still loading", which is why the two states
contradict each other on screen.

## Fix direction

The key is the credential. `connectDeviceLinkPairing` already asserts this
(`if !isSignedIn { signIn() }`, MobileShellComposite+DeviceLink.swift:64). The
unauthenticated auth-state sync must not revoke it: a device holding a usable
identity and pin (`MobileDeviceLinkClient.shared.hasAnyPairedDevice()`) is
authenticated regardless of Stack account state.

Do **not** simply make `signOut()` a no-op when a pairing exists — that would
break genuine user-initiated sign-out. The sync path is what needs the guard,
and no production caller of `signOut()` appears in `Packages/iOS` or `ios/`
(only tests), so it is invoked through a binding/closure that still needs
locating.

## Why this is the same bug family

Third instance today of the account path asserting authority over a credential
that was never account-derived — after paired-Mac persistence bailing on a nil
scope, and the build-compatibility wrapper silently dropping writes. Phase 4's
deletion of the legacy/account pairing surface is the real cure.
