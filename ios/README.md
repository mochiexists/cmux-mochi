# cmux iOS

SwiftUI iOS/iPadOS shell for the CMUXMobileCore production path.

Current phase:

- Stack Auth sign-in gate with Apple, Google, email code, and a debug-only `42` shortcut
- QR/manual pairing surface
- CMUXMobileCore pairing payload and attach-ticket decoding
- injectable `CmxByteTransportFactory` runtime hook
- isolated preview host data when no concrete transport is installed
- workspace list, workspace detail, terminal dropdown, and input bar

No Rust, Iroh, or Zig dependency is linked into this shell. Concrete route implementations should enter through `CMUXMobileRuntime`.

Build and reload the simulator:

```bash
ios/scripts/reload.sh --tag iossh
```

Run package tests:

```bash
swift test --package-path ios/cmuxPackage
```

## Build compatibility and production-auth DEV builds

A DEV iOS build connects only to the Mac DEV build with the same tag. BETA,
INTERNAL, and App Store iOS builds connect only to Stable or Nightly Mac builds.
Account environment does not change that compatibility boundary.

Use `--prod-auth` only when a tagged DEV build needs to test production account,
registry, or API behavior:

```bash
ios/scripts/reload.sh --tag my-tag --device-only --prod-auth
```

What `--prod-auth` does:

- Bakes `CMUXAuthEnvironment=production` into the app's Info.plist (via the
  `CMUX_IOS_AUTH_ENV` build setting), so the build signs in against the
  production Stack project and uses `https://cmux.com` for the device
  registry/API and the magic-link callback.
- Makes the presence worker follow the auth channel: the app resolves the
  production presence instance (see `PresenceClient.productionServiceURL`) so
  compatible Macs appear in Computers. The worker URLs live only in Swift;
  the script bakes no copy, and an explicit `CMUX_PRESENCE_BASE_URL` still
  wins.
- Skips the dogfood auto sign-in/auto-pair (those credentials belong to the
  development Stack project). Sign in in-app with the same account as your
  matching tagged DEV Mac.
- On first launch after switching auth environments on the same install, the
  app clears the previous environment's session/caches (tokens and user ids
  are per-Stack-project), so you start signed out instead of restoring a
  stale identity.

The system Camera routes release QR links (`cmux-ios://…`) to an official iOS
app and DEV QR links (`cmux-ios-dev://…`) to a DEV iOS app. The authenticated
Mac status supplies the exact instance tag, which the app validates before it
saves or adopts the connection.

Without the flag, the same override is available by bundling a
`LocalConfig.plist` with an `AuthEnvironment` string of `production` (see
`MobileAuthComposition`); a `LocalConfig.plist` entry wins over the baked
Info.plist value.

## TestFlight beta (cloud lane)

`ios/scripts/cloud-testflight.sh` is the turnkey helper for cutting a TestFlight
beta. It builds the heavy GhosttyKit + Swift Release compile on a leased fleet
Mac (same maclease pool as the device cloud reload, m1ultra excluded), so the
build stays off this Mac's CPU. The fleet produces an UNSIGNED Release archive
for the fork beta bundle id `com.cmux-mochi.ios` (no signing material ever lands
on the shared Macs), downloads it locally, then hands it to
`ios/scripts/upload-testflight.sh --archive-path`, which does the local export,
re-sign with the Apple Distribution cert (re-adding `aps-environment=production`),
strict codesign verification, and TestFlight upload.

```bash
# Dry run: build + export + re-sign + verify aps-environment=production, NO upload
ios/scripts/cloud-testflight.sh --no-upload

# Full lane: build on the fleet and upload to TestFlight (internal "cmux beta" group)
ios/scripts/cloud-testflight.sh
```

A standalone cmux clone with no cmuxterm-hq checkout transparently falls back to
a LOCAL Release archive (`--local` forces it), then takes the same export path.

Internal testers get every uploaded build immediately, with no Beta App Review.
The inherited upload helper still contains external-distribution support, but
the fork's official GitHub Actions lane does not provision or publish an
external audience. Do not use `--external` for a fork release unless that
audience and its signing/distribution contract are deliberately restored first.

## TestFlight GitHub Actions signing

`.github/workflows/ios-testflight.yml` uses manual export signing because Xcode's
automatic App Store Connect export has produced IPAs whose signed app
entitlements omit `aps-environment=production`. That upload is intentionally
blocked because TestFlight push would silently fail. The workflow is manual-only,
publishes only from `main`, signs `com.cmux-mochi.ios` with Atlas Codes team
`599WAZ6282`, exports with `testFlightInternalTestingOnly=YES`, and assigns the
processed build to the internal TestFlight group. The inherited
`marketing_version_override` input is explicitly rejected because this fork has
no external TestFlight lane.

Required GitHub secrets:

- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `ASC_API_KEY_P8_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_BASE64` (base64-encoded `.p12` for an Apple Distribution certificate on team `599WAZ6282`)
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_BETA_PROVISIONING_PROFILE_INTERNAL_BASE64` (preferred; base64-encoded App Store profile for `com.cmux-mochi.ios`, with `aps-environment=production`)
- `IOS_BETA_PROVISIONING_PROFILE_BASE64` (fallback name for the same `com.cmux-mochi.ios` profile)

## App Store production lane

The production App Store lane is separate from the TestFlight beta lane. It uses
the same archive/export/re-sign verification path, but switches the submitted
identity to the App Store bundle id and stops before App Review submission unless
the operator explicitly confirms submission in CI.

```bash
# Build, export, re-sign, verify, and upload the production App Store build
ios/scripts/upload-app-store.sh

# Dry run: export + re-sign + verify aps-environment=production, no upload
ios/scripts/upload-app-store.sh --export-only

# Run the read-only ASC readiness package after upload
ios/scripts/validate-app-store-release.sh --app "$ASC_APP_ID" --build-number "$CF_BUNDLE_VERSION" --wait-build --strict
```

Defaults:

- Bundle ID: `com.cmux.app`
- Marketing version: `CMUX_IOS_APPSTORE_MARKETING_VERSION` in `ios/Config/Shared.xcconfig`
- Display name: `cmux`
- Provisioning profile: `cmux App Store Distribution`
- Entitlements: `Config/cmux-release.entitlements`

The review package lives in `ios/AppStoreReview/`:

- `review-notes.md` is the pasteable App Store Connect Review Information notes source.
- `metadata-screenshots-checklist.md` is the blocking checklist for metadata, screenshots, privacy, account deletion, and payment gating.

`.github/workflows/ios-app-store.yml` is manual-only. It uploads a production
build, waits for ASC processing, runs `ios/scripts/validate-app-store-release.sh`,
and submits for review only when `submit_for_review` is set.

Additional production workflow requirements:

- Repository variable `IOS_APPSTORE_APP_ID`
- Secret `IOS_APPSTORE_PROVISIONING_PROFILE_BASE64` (base64-encoded App Store profile for `com.cmux.app`, with `aps-environment=production`)
