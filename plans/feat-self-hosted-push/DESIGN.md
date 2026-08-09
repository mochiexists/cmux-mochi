# Self-hosted push — your Mac is the push server

Status: proposed. Decision (operator, 2026-07-25): the fork's mobile story is
**fully private and self-hosted** — no account required to pair (shipped: the
"Continue without an account" door), and no third-party server in the
notification path either. Upstream forwards notification text through cmux
servers to APNs; this fork sends it from the paired Mac straight to Apple.

## Today, the blockers

- Push is account-scoped: the phone's device token is uploaded post-sign-in to
  cmux's push service (`DeferredSignInHook` → "post-sign-in token re-upload").
  Skip sign-in and there is no push at all.
- Notification text (title + body, drawn from terminal output) transits cmux
  servers. For an operator whose panes carry client work, health data, and API
  keys, "Hide content" is a mitigation, not a boundary.
- Nothing on the Mac side knows how to talk to APNs.

## The insight

APNs is just an authenticated HTTP/2 endpoint. Any process holding an APNs Auth
Key (.p8) can POST to it — including an always-on Mac. No hosting, no bill, no
third party. The M4 already never sleeps (`pmset sleep 0`), which is exactly the
uptime a push sender needs.

**Bonus property:** the push itself travels Mac → Apple → phone over cellular.
Only the one-time token handoff needs the tailnet, so notifications keep arriving
when the phone is off the tailnet entirely — including on networks where
Tailscale is degraded (operator travels to China; peer traffic passes, but this
path does not even depend on it).

## Target model

```
 phone                          paired Mac (M4)                  Apple
   │  device token (APNs)            │                             │
   ├── over existing pairing RPC ───▶ │ stores token per device     │
   │                                  │ (Keychain, with .p8 key)    │
   │                                  │                             │
   │        pane wants attention ────▶│ sign ES256 JWT (kid+teamId) │
   │                                  ├── POST /3/device/<token> ──▶│
   │◀───────────── APNs delivery ─────┼─────────────────────────────┤
```

- Credentials: APNs Auth Key `.p8` + Key ID + Team ID (599WAZ6282), created once
  in the Apple developer account. Stored in the Mac's Keychain, never in the repo.
- Endpoint: `api.sandbox.push.apple.com` for `aps-environment: development`
  builds (what `ios/Config/cmux.entitlements` ships today), `api.push.apple.com`
  for TestFlight/App Store builds. Mismatch = `BadDeviceToken`; make it explicit,
  not inferred.
- `apns-topic` = the app's bundle id (`dev.cmux.ios` / tagged `dev.cmux.ios.mob`).
- JWT: ES256, refreshed at most once per 20 min, valid ≤ 1 h — cache it.
- Payload keeps upstream's **Hide content** switch: generic body when on. Honor
  the `.time-sensitive` interruption level the entitlements already allow.

## Phases (each independently shippable)

- **P1 — token handoff.** Phone sends its APNs device token to the paired Mac over
  the existing pairing RPC; Mac persists it per-device. No sending yet; verify
  with a log line and a stored token.
- **P2 — Mac APNs client.** Keychain-backed `.p8` + JWT signer + URLSession HTTP/2
  POST. A `cmux mobile push test "hello"` CLI verb proves the loop end to end.
- **P3 — wire the real notifications.** Route the existing pane-attention
  notification path to the local sender when a self-hosted key is configured;
  fall back to nothing (not to cmux servers) when it is not. Respect Hide content.
- **P4 — polish.** Multi-phone fan-out, token rotation/invalidation
  (`410 Unregistered` → drop token), sandbox/prod switch surfaced in settings,
  and a "push is self-hosted" indicator so the privacy property is visible.

## Risks / notes

- Device tokens change on reinstall and can be invalidated by Apple — handle 410.
- The Mac must be awake to send; that is the M4's job description.
- Development-environment tokens only work against sandbox APNs. A TestFlight
  build needs a production key path — decide before P4.
- Keep the sender behind a protocol so a future Iroh/relay transport does not
  change the notification path.
