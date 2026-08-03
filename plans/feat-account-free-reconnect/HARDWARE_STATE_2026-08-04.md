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
