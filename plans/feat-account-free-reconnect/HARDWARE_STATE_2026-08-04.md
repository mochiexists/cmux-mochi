# Hardware state, verified 2026-08-04

Measured, not assumed. Every line below was read off the machine or the device.

## Macs

Both rebuilt from HEAD today and relaunched. Both listen on **58525**, the port
derived from the tag `endpoint-stability`.

| | M5 (`timapple-m5`, 100.112.69.84) | M4 (`s-macbook-pro-2`, 100.82.2.18) |
|---|---|---|
| bundle | `com.cmux-mochi.debug.endpoint.stability` | same |
| DeviceLink SPKI SHA-256 | `8dd06915fb28a…` | `7a265d170d54…` |
| routes published | loopback, v4, v6, MagicDNS | loopback, v4, v6, MagicDNS |

Both fingerprints **match the pins the phones already hold**, so rebuilding the
Mac app did not invalidate any pairing — the identity is keychain-backed and
survives a rebuild. Verified with `openssl s_client -alpn cmux-devicelink/1`
against each listener and hashing the SPKI.

> Probe gotcha: hashing a *failed* `s_client` yields
> `e3b0c44298fc1c14…`, the SHA-256 of empty input. A Mac cannot reach its own
> tailnet IP, so probe the local Mac over loopback or you will "find" a wrong
> fingerprint that is really an empty pipe.

The M4 additionally runs `com.cmux-mochi` on 58465 and
`com.cmux-mochi.nightly` on **61236** (a drifted port, predating the fail-closed
listener). Different bundles and ports, so they do not collide with 58525, but
three cmux apps on one Mac make "which one did I scan?" a real hazard.

## Phones

Both are on the HEAD build (`com.cmux-mochi.ios.endpoint-stability`), installed
after `c66e7a4758`.

| | iPhone 16 Pro Max | iPhone 17 Pro Max |
|---|---|---|
| Macs in `paired_macs` | **M5 and M4**, both tag `endpoint-stability` | **M5 only** |
| cold-launch reconnect | connects in **1.3 s** | (M5 only) |

**The iPhone 17 does not list two computers because it was only ever paired with
one.** Read directly out of its container: one row, one entry in
`devicelink.pairingIDsByMacDeviceID`. Both reviewers proposed a build-tag
mismatch, and the code supports that failure — but it is not what happened here:
both phones and both Macs carry the identical tag, and the 16 holds both rows
under it. The 17 simply needs to scan the M4's QR code.

The 16 dials only the M5 because the candidate loop stops at the first Mac that
connects — one active connection at a time, by design. A second stored Mac is
selectable, not simultaneously connected.

## Reading a phone's real pairing state

Faster and more truthful than any log:

```sh
xcrun devicectl device copy from --device <udid> --source / \
  --destination /tmp/p --domain-type appDataContainer \
  --domain-identifier com.cmux-mochi.ios.endpoint-stability
sqlite3 "/tmp/p/Library/Application Support/cmux/paired-macs.sqlite3" \
  "select mac_device_id, display_name, instance_tag, is_active from paired_macs;"
plutil -p "/tmp/p/Library/Preferences/com.cmux-mochi.ios.endpoint-stability.plist" \
  | grep -A4 pairingIDsByMacDeviceID
```

## Minting a pairing code without the UI

Local-socket only, by deliberate design — no network peer can enumerate or
revoke paired devices:

```sh
python3 -c '...' /private/tmp/cmux-debug-<tag>.sock   # mobile.pairing.code.create
```

**Security note:** that socket is mode **0666** on both Macs. Any local process
can mint a pairing code and pair itself to the Mac. The DeviceLink design
correctly keeps these verbs off the network, and then the socket gives them away
locally. Worth tightening to 0600 before this leaves dogfood.

## Build footguns hit today

- `scripts/reload.sh` fails in the Ghostty zig helper (`undefined symbol:
  _getenv` …). `CMUX_SKIP_ZIG_BUILD=1` is required.
- `ios/scripts/reload.sh --device` needs `--team 599WAZ6282`; without it Xcode
  reports "Signing for cmux requires a development team".
- `--simulator` resolves with `OS:latest`, so the name must exist on the newest
  installed runtime (only `MochiSync-iPhone-27beta` on iOS 27.0 here), not
  merely be booted.

---

# Open blocker (2026-08-04, later): the connection succeeds but does not stick

## Simulator — FIXED and verified

Cold-launch reconnect on `MochiSync-iPhone-27beta`, fresh log each run:

```
[0.232] dial candidates: 127.0.0.1:58525 …
[0.244] client verify: server 8dd06915fb28 expected 8dd06915fb28 -> accept
[0.276] dial finished: connected
```

Took three fixes, all committed: the Stack ticket-mint on the loopback dial
(`c66e7a4758`), the missing keychain entitlement on unsigned simulator builds
(`10e1f4d7a1`), and fail-closed loopback TLS. Pairing and reconnect both work.

## iPhone 16 — the connection loops

The dial **succeeds** and then is re-attempted every ~12–14 s, indefinitely:

```
[38372.841] dial finished: connected
[38374.532] dial finished: connected
[38388.600] dial finished: connected
[38400.466] dial finished: connected
```

Between a success and the next attempt there is **no error and no disconnect
line** — only `macupdate.hint caps=22 version=0.64.20` and
`sync.transport=hybrid`. So nothing is tearing the transport down; something is
re-invoking `reconnectActiveMacOutcome` because the session state never
registers as connected.

The Mac agrees the connection is good: `verify … -> admit`,
`admitted pairedDevice`, repeatedly, about once a second.

User-visible symptom: the workspace list and prior chat render, but tapping
through never connects, while the Mac app is plainly running.

**This is the next thing to fix, and it is NOT a DeviceLink transport problem** —
mutual TLS, pinning and admission all succeed on both sides.

## CONFIRMED, with the mechanism (same day, on the iPhone 16)

An idle app connects once and stays quiet. The loop starts the moment the user
tries to use it, and then runs at roughly **one full cycle per second**:

```
[1313.017] reconnect scope … -> dial finished: connected -> sync.transport=hybrid
[1314.050] reconnect scope … -> dial finished: connected -> sync.transport=hybrid
[1314.934] reconnect scope … -> dial finished: connected -> sync.transport=hybrid
[1315.751] reconnect scope …
```

The driver is **connection recovery**, not the reconnect path itself:
`MobileShellComposite+ConnectionRecovery.swift:218,226-230` sets
`connectionState = .disconnected` and clears the remote context, then :236 calls
`reconnectActiveMacOutcome`. The redial succeeds — and recovery is triggered
again immediately, so the connection is destroyed as fast as it is made and the
UI never settles.

**The missing fact is which trigger fires.** `recoverMobileConnection(trigger:)`
(:64) accepts `.foreground`, `.liveness`, `.eventStreamEnded`,
`.subscriptionStartFailed`, `.transportWriteTimedOut`, `.networkChange`,
`.presencePush`, `.manual`. The shape — connect, then recover within ~1 s,
forever — points at `.eventStreamEnded` or `.subscriptionStartFailed`: the
DeviceLink channel opens, the event-stream subscription over it fails at once,
recovery redials, repeat.

`beginConnectionRecovery` already logs its trigger through
`MobileDebugLog.anchormux` (:249), but those lines are NOT in the on-device
debug log — capture them first (os_log / `devicectl device process
launch --console`, or route that line into `MobileDeviceLinkDiagnostics`). One
run with the trigger visible should end this.

Do not re-derive: the transport is fine. `dial finished: connected` is true
every single cycle.

## Stale apps on the phones

The iPhone 16 carries three bundles: `com.cmux-mochi.ios.endpoint-stability`
(the real one), plus `com.cmux-mochi.ios` and `dev.cmux.ios.nightly`, which hold
no pairings and correctly show no computers. They are only a source of confusion
— delete the latter two.

---

# FIXED: durable connections (2026-08-04, late)

`35e0e31dd8`. A stored-Mac reconnect built a synthetic attach ticket claiming
`manual-<host>:<port>` as the Mac's device id. Upstream's post-connect check
`applyHostReportedIdentity` compared that placeholder to the Mac's real id,
called it `device_id_mismatch`, and disconnected — ~90 ms after mutual TLS, the
build check and the instance-tag check had all passed. The dial reported success
first, so the UI flashed connected then sat offline with a Reconnect button that
could only repeat the cycle.

Verified by UI test on BOTH phones: one connect, **zero**
`connected -> disconnected` transitions, `list=connected connection=connected`
still true at 290 s (16) and 156 s (17).

Both phones now hold pairings to both Macs. The 17 was paired to the M4
**headlessly** — mint over the Mac's local socket, inject via
`DEVICECTL_CHILD_CMUX_DOGFOOD_ATTACH_URL` at launch. No QR, no tapping. The same
trick makes delete-and-repair scriptable.

## Open, reported from the device 2026-08-04 17:14

Screenshot: connected to `🍋's MacBook…` (the **M4**, so the M4 dials fine), one
workspace `cat` listed.

1. **The machine filter does nothing.** Changing the selection at the top does
   not change the listed chats.
2. **Rows do not say which machine they belong to** in All Machines, so a
   combined list is unreadable.
3. **Only one chat shows**, which is why the list looks like a single machine.
   `cat` was the workspace seen on the M5 during the 17's UI test, and it is
   still the only row while the M4 is selected — so the list is probably not
   re-fetched per machine and is showing one Mac's workspaces under the other's
   name. Check `refreshSecondaryMacWorkspaces` / `switchToMac` and the
   `workspacesByMac` keying before assuming the M4 returns nothing.

Note `loadPairedMacs` never appeared in any device log during these runs — worth
confirming it runs at all, since the computer list is built from it.

4. **`enroll route <ipv4>:58525 failed: malformedResponse`** on the M4; IPv6
   saved the pairing. A v6-less network would fail the pairing outright.

## Test harness notes

- Run the UI test with `PRODUCT_BUNDLE_IDENTIFIER=com.cmux-mochi.ios.<tag>` and
  `CMUX_DEV_TAG=<tag>`. Without them `xcodebuild test` installs the UNTAGGED app
  with an empty database, and every finding is meaningless.
- The test's computer-name assertion is too strict: the list shows *workspace*
  names, so it reports failures on a working phone. Fix the assertion.

## CORRECTION: 35e0e31dd8 fixes the disconnect the WRONG way

Reported from the device: the M4 and the M5 both list the same `cat` workspace,
and opening it loads nothing (it used to). That is a regression from the fix,
not a pre-existing list bug.

`applyHostReportedIdentity` (MobileShellComposite.swift ~2839) has two branches:

- `ticket.macDeviceID.isEmpty` -> **adopt**: rebuild the ticket with the
  Mac's reported id and call `adoptForegroundMacIdentity(reportedID)`, whose own
  comment says it exists so "the Computers screen recognizes this Mac as
  connected and secondary aggregation excludes it (no duplicate connection to
  self)".
- otherwise -> **verify**: `authenticatedDeviceMatches`, else
  `rejectForegroundHostIdentity(reason: "device_id_mismatch")`.

The old placeholder `manual-<host>:<port>` was neither empty nor real, so it took
the verify branch and was rejected — the ~90 ms disconnect.

`35e0e31dd8` put the REAL id in the ticket. That passes verification (hence the
durable connection, which is genuine) but now **skips the adopt branch**, so
`adoptForegroundMacIdentity` never runs and the foreground workspace aggregate is
never re-keyed onto the real Mac. Both Macs then share one bucket: same single
workspace under either selection, and terminals that will not load.

**Likely correct fix:** give the synthetic stored-Mac ticket an EMPTY
`macDeviceID` so upstream's adopt path runs and takes the Mac's reported id.
That is the flow the adopt branch was written for. Keep `pairedMacDeviceID`
flowing to `connect(...)` for route/pin selection; it is only the ticket's
claimed id that must be empty.

Verify with the UI test on the 17 (both Macs paired):
- zero `connected -> disconnected`
- switching Macs changes the listed workspaces
- opening a workspace loads a terminal
