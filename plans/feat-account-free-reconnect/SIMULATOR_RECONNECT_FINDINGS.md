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

## The live lead

**The client TLS verify block never executes.** `DeviceLinkTLS.verificationObserver`
was added and wired into the device log; across three dials it produced no
output at all, while `sec_protocol_options_set_verify_block` is definitely
installed on those options. So the handshake stalls *before* the client
validates the server certificate, and both ends then time out.

That points at the handshake never starting properly rather than at any
admission or pinning decision. Next things to check, in order:

1. Whether `sec_identity_create(identity)` returns nil inside `applyCommon`
   on the simulator. If it does, no client certificate is attached; the server
   has `peer_authentication_required(true)` and both sides can sit waiting.
   Note `tlsOptions(forPairingID:)` returning non-nil does **not** prove this —
   it only proves a `SecIdentity` was built, not that `sec_identity_create`
   accepted it.
2. Whether the simulator keychain returns an identity whose private key is not
   usable for signing (simulator keychain differs from device).
3. Whether the reconnect transport is even reaching `.debugLoopback` — add a
   log of the host:port actually dialled, which the current logging omits.

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
