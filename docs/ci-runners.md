# CI runners

The Mochi fork does **not** use Blacksmith. Release automation has one explicit
split:

- GhosttyKit and the release Ghostty CLI helper run on GitHub-hosted `macos-15`.
- The signed/notarized app release runs on the self-hosted GitHub Actions
  signing-runner label through `runs-on: [self-hosted, cmux-mochi-m4pro]`.

This is intentional. Zig 0.15.2 currently links the Ghostty helper/GhosttyKit
reliably on macOS 15, while the app release must compile against the macOS 26
SDK and use the signing runner's notary setup.

Most non-release CI jobs still pick runners from repository variables so they
can be redirected without a workflow edit. Do not infer release routing from
those generic CI variables.

| Variable            | Used by                                                    | Current Mochi value         | Fallback baked into the workflow |
| ------------------- | ---------------------------------------------------------- | --------------------------- | -------------------------------- |
| `LINUX_RUNNER`      | Linux CI jobs                                              | repo variable               | workflow-specific                |
| `MACOS_RUNNER_15`   | generic macOS 15 CI lanes                                  | `macos-15`                  | workflow-specific                |
| `MACOS_RUNNER_26`   | generic macOS 26 CI lanes                                  | repo variable where needed      | workflow-specific            |
| `MACOS_RUNNER_26_RELEASE` | CI release-build validation, not the real tag release | repo variable               | workflow-specific                |
| `MACOS_RUNNER_IOS`  | iOS simulator tests + TestFlight upload                    | repo variable               | workflow-specific                |

Check current values:

```bash
gh variable list --repo mochiexists/cmux-mochi
```

## Release Flow

Before an app release can consume a new Ghostty submodule SHA, publish and pin
its GhosttyKit archive:

```bash
gh workflow run build-ghosttykit.yml --repo mochiexists/cmux-mochi --ref main
```

After that workflow publishes
`xcframework-<ghostty-sha>-crashsubdir-cmux-crash-v1` to
`mochiexists/ghostty`, download the asset, compute its SHA-256, and add one
line to `scripts/ghosttykit-checksums.txt`.

Then run:

```bash
./tests/test_ci_ghosttykit_checksum_present.sh
./scripts/download-prebuilt-ghosttykit.sh
./tests/test_ci_ghosttykit_checksum_verification.sh
./tests/test_ci_release_sdk_lane.sh
./tests/test_ci_self_hosted_guard.sh
./scripts/release-pretag-guard.sh
```

Only cut the app tag after those pass. If a tag workflow already failed and the
fix needs a new commit, do not move that tag; bump to the next version and cut a
new tag.

## Guard

`tests/test_ci_self_hosted_guard.sh` keeps generic CI lanes from accidentally
landing on ambiguous self-hosted labels or bare GitHub-hosted runners. It has
two explicit release exceptions:

- `.github/workflows/build-ghosttykit.yml` may pin `runs-on: macos-15`.
- `.github/workflows/release.yml` may pin `runs-on: [self-hosted, cmux-mochi-m4pro]`.

Those exceptions are intentional and should stay narrow. Do not add other
self-hosted labels to required CI without updating this document and the guard.
Do not put concrete self-hosted runner host names in public docs, workflows, or
logs.
