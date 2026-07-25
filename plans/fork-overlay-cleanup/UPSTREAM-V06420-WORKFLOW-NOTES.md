# Upstream v0.64.20 Workflow Notes

Captured while replaying the Mochi fork from upstream `v0.64.19` onto
`v0.64.20`. This records upstream workflow behavior that the fork does not
currently adopt, or adopts with different repository, identity, and release
policy.

This is a research note, not a recommendation to enable these paths unchanged.
Anything adopted later must use Mochi bundle IDs, signing identities, Sentry
project, secrets, release URLs, and repository gates.

## Inventory result

No upstream v0.64.20 workflow file was deleted. The fork retains the complete
`.github/workflows` file inventory and modifies 13 workflows:

| Workflow | Fork difference |
| --- | --- |
| `build-ghosttykit.yml` | Uses GitHub-hosted macOS 15, publishes to `mochiexists/ghostty`, emits runner diagnostics, uploads a workflow artifact, and fails when the release token is unavailable. |
| `ci.yml` | Cancels superseded `main` runs, uses Mochi app identities, isolates `CmuxRemoteSession` suites, and restores the fork's display-dependent UI regression lane. |
| `cloud-vm-migrate.yml` | Keeps all jobs but gates credential-bearing upstream migrations to `manaflow-ai/cmux`. |
| `cloud-vm-smoke.yml` | Keeps the job but gates upstream cloud smoke deployment to `manaflow-ai/cmux`. |
| `cmux-tui-nightly.yml` | Keeps manual dispatch while leaving the upstream schedule disabled. |
| `ios-app-store.yml` | Replaces the upstream Apple team with Mochi team `599WAZ6282`. |
| `ios-testflight.yml` | Keeps upstream SHA/history/path/assignment logic, replaces Apple identities, and disables the scheduled upload trigger. |
| `nightly.yml` | Keeps the upstream split build architecture but makes publication manual, selects a Mochi runner lane, replaces identities/destinations, and removes upstream-only publication steps. |
| `perf-activation.yml` | Uses the `cmux Mochi DEV` app and executable names. |
| `presence.yml` | Keeps the jobs but gates upstream presence test/deploy infrastructure to `manaflow-ai/cmux`. |
| `release.yml` | Uses the Mochi helper/signing topology, identities, Sentry project, GitHub feed, and release paths; removes upstream-only publication/profile steps. |
| `test-depot.yml` | Keeps the workflow but gates the upstream Depot job and uses the Mochi Ghostty release. |
| `update-homebrew.yml` | Disables automatic post-release execution until a Mochi tap exists and gates the upstream publishing job. |

This distinction matters: most workflow code was retained or adapted. The list
below is the exact intentionally disabled or removed behavior.

## Exact upstream behavior disabled or removed

### Nightly

- Disabled automatic `main` push builds.
- Disabled both upstream schedules (`17 */6 * * *` and `47 8 * * *`).
- Removed Cloudflare R2 upload of `nightly/appcast.xml`.
- Removed the final force-move and push of the `nightly` Git tag.
- Removed the upstream Developer ID provisioning-profile injection and its app
  ID, WebAuthn entitlement, and all-devices validation.
- Replaced upstream's third-party Linux decision runner and automatic macOS 26
  runner selection with GitHub-hosted Linux plus an explicit Mochi
  signing-runner/hosted-runner choice.

### Stable release

- Removed Cloudflare R2 upload of `stable/appcast.xml`, including its
  highest-semver overwrite guard.
- Removed the upstream Developer ID provisioning-profile injection and its app
  ID, WebAuthn entitlement, and all-devices validation.
- Replaced the generic macOS 26 runner fallback with the Mochi self-hosted ARM64
  signing label.

### iOS and package publication

- Disabled the TestFlight `17 */2 * * *` schedule. Manual dispatch still uses
  the retained SHA history, path gate, upload history, and assignment retry
  machinery.
- Disabled Homebrew's automatic `workflow_run` trigger because a
  `mochiexists/homebrew-cmux` tap does not yet exist.
- Left the TUI nightly schedule disabled; manual dispatch remains.

### Upstream infrastructure

- Gated `presence.yml`, `cloud-vm-migrate.yml`, `cloud-vm-smoke.yml`, and
  `test-depot.yml` jobs to `manaflow-ai/cmux`. Their implementations remain in
  the tree for study, but they cannot deploy or consume upstream infrastructure
  from the fork.

## Replacements and fork additions

These were not removals:

- Upstream repository, Ghostty repository, app names, bundle IDs, Apple team,
  release URLs, Sparkle feeds, and Sentry destinations were replaced with Mochi
  values.
- Stable and nightly appcasts publish through GitHub Release assets rather than
  `files.cmux.com`.
- The release helper build is pinned to GitHub-hosted macOS 15 and cached by
  Ghostty SHA plus build-script inputs; every cached or fresh helper is still
  checked for universal architecture.
- Nightly can explicitly choose the Mochi M4 signing lane or the hosted macOS 15
  fallback. Stable release has no signing-runner fallback.
- Runner identity diagnostics and architecture guards were added.
- Remote-daemon provenance attestation is retried and reported, but remains
  non-fatal after the signed/notarized/appcast/immutable-asset gates pass.
- CI retains Mochi-specific app naming, main-run cancellation, the
  `CmuxRemoteSession` suite isolation workaround, and the virtual-display UI
  regression lane.
- GhosttyKit publication now uploads a workflow artifact and fails closed when
  the Mochi release token is missing.

## Non-workflow replay cleanup

The v0.64.20 replay also omitted or removed obsolete overlay material:

- The old version-bump commit and its revert were not replayed. This branch
  remains at the v0.64.20 version/build baseline until release preparation.
- The old GhosttyKit checksum-pin commit was not replayed because v0.64.20
  carries a newer Ghostty base. The current exact submodule/checksum state is
  validated separately.
- `.github/swift-file-length-budget.tsv` remains deleted because upstream
  removed the complete file-length budget system in v0.64.20; retaining only
  the fork's stale budget file would create a dead second source of truth.
- The fork copy of `v2AwaitCallback` was removed after v0.64.20 introduced the
  same helper in `TerminalController+BrowserWorkerSupport.swift`.

## Nightly architecture worth studying

Upstream split the nightly into four jobs:

1. `refresh-compilation-cache`
   - Refreshes a universal Release compilation cache on a matching runner and
     pinned Xcode version.
   - Bounds the cache at 5 GiB and sanitizes the Swift package cache.
2. `build-nightly-ghostty-cli-helper`
   - Builds the universal Ghostty CLI helper independently.
   - Transfers it as a short-lived workflow artifact.
3. `build-nightly-app`
   - Builds and strips an unsigned universal app.
   - Transfers the unsigned app as a short-lived workflow artifact.
   - Uploads app dSYMs independently of signing.
4. `build-sign-notarize-nightly`
   - Downloads the unsigned app and helper.
   - Injects the helper, verifies architectures and the diff sidecar, signs,
     notarizes, generates Sparkle feeds, attests remote-daemon assets, and
     publishes.

This separates expensive compilation from the credential-bearing signing job
and makes build products explicit. The fork previously built the app and helper
inside one signing job, with extra checks that the selected commit was still
the current `main` HEAD before and after the build.

## Upstream paths intentionally not enabled

- Automatic nightly triggers:
  - push to `main`
  - scheduled runs
  - moving the `nightly` tag automatically
- Cloudflare R2 publication of the nightly appcast at
  `files.cmux.com/nightly/appcast.xml`.
- Upstream repository, app, Sentry, signing-team, bundle-ID, and feed values.
- Upstream Developer ID provisioning-profile injection and WebAuthn entitlement
  validation. The Mochi signing profile and entitlements need a separate
  decision before adopting this.

The fork remains manual-dispatch only and publishes its Sparkle appcast and
assets through the `mochiexists/cmux-mochi` GitHub nightly release.

## Upstream behavior retained in the v0.64.20 replay

- Split build/helper/signing job topology.
- Reusable Xcode compilation-cache preparation and size bounds.
- Unsigned app and helper artifact transfer.
- Dedicated Ghostty theme-picker regression.
- Architecture checks for the app binary, CLI, Ghostty helper, and diff
  sidecar.
- Centralized `scripts/ci/notarize-nightly-dmg.sh` notarization path.
- Remote-daemon asset generation, manifest injection, provenance attestation,
  retry, and immutable-asset checks.
- Fork-specific manual trigger, selectable M4 signing runner, Mochi identities,
  Sentry destination, GitHub Release publication, and non-fatal attestation
  retry behavior.

## iOS TestFlight workflow worth studying

Upstream `ios-testflight.yml` is substantially more than a build-and-upload
workflow:

- A scheduled beta lane compares `main` with the last uploaded SHA.
- A path gate avoids notifying testers for changes that cannot affect iOS.
- Workflow history and metadata artifacts prevent duplicate uploads.
- Manual marketing-version overrides are kept separate from the canonical beta
  history.
- Assignment state is persisted as artifacts, allowing assignment-only retries
  without rebuilding or re-uploading the IPA.
- Internal builds use a separate bundle ID so internal and external apps can
  coexist on a device.
- History lookup fails closed for scheduled uploads to avoid duplicate builds.
- App Store Connect assignment retries account for expired artifacts and older
  workflow versions.

For the fork replay, scheduled execution remains disabled. Upstream assignment
and history logic is retained so it can be evaluated under Mochi identities
without silently enabling automated external distribution.

## Other upstream workflow differences

- `presence.yml` runs tests on relevant pull requests and deploys on relevant
  pushes to upstream `main`. The fork keeps deployment manual and gates it to
  the upstream repository condition so fork CI cannot deploy upstream
  infrastructure.
- Stable release verifies the bundled diff sidecar before signing.
- Stable release can inject and validate a Developer ID provisioning profile
  for WebAuthn.
- Stable release publishes the appcast to
  `files.cmux.com/stable/appcast.xml` through Cloudflare R2.
- Upstream release and nightly jobs upload dSYMs to upstream's Sentry project;
  the fork must always use `codes-o3/cmux-mochi`.

## Follow-up investigation

1. Compare split-job nightly duration and reliability with the fork's previous
   single signing job.
2. Decide whether compilation caches are safe and useful on the fork's
   selectable hosted/self-hosted runner lanes.
3. Evaluate whether Mochi needs a Developer ID provisioning profile for its
   actual entitlements before porting upstream's profile checks.
4. Decide whether GitHub Release appcasts remain sufficient or whether a
   Mochi-owned object store should provide stable, atomic appcast publication.
5. Adapt the TestFlight SHA, path-gating, and assignment-only retry model to
   Mochi's App Store Connect apps without enabling scheduled distribution until
   it has an explicit release-policy decision.
6. Keep repository gates and fork-overlay audits around every credentialed
   deploy path.
7. Decide whether Mochi needs the Developer ID provisioning profile and
   WebAuthn entitlement checks before the next stable release; do not copy the
   upstream profile or team identifiers.
8. Study the nightly completion-marker model before restoring automation:
   GitHub Release publication, appcast publication, and the moving `nightly` tag
   need one explicitly chosen source of truth.

Useful future comparison commands:

```bash
git diff --stat v0.64.20 -- .github/workflows
git diff --unified=20 v0.64.20 -- .github/workflows/nightly.yml
git diff --unified=20 v0.64.20 -- .github/workflows/release.yml
git diff --unified=20 v0.64.20 -- .github/workflows/ios-testflight.yml
```
