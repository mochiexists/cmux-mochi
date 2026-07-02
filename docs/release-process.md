# cmux Mochi release process

This is the fork release playbook. Keep it aligned with `FORK.md`,
`.github/workflows/nightly.yml`, `.github/workflows/release.yml`, and
`scripts/release-pretag-guard.sh`.

## Release lanes

There are three distinct lanes:

| Lane | Trigger | Publishes public release assets? | Purpose |
|---|---|---:|---|
| Branch nightly proof | `nightly.yml` on a branch | No | Prove the M4 build/sign/notarize/package path before touching `main`. |
| Main nightly publish | `nightly.yml` on `main` | Yes, rolling `nightly` prerelease | Exercise the publish/update flow with the isolated nightly app. |
| Stable release | push tag `vX.Y.Z` | Yes, stable release | Ship production `cmux Mochi`. |

The nightly app is isolated from stable:

- app name: `cmux Mochi NIGHTLY`
- bundle ID: `com.cmux-mochi.nightly`
- URL scheme: `cmux-nightly`
- Sparkle feed: `https://github.com/mochiexists/cmux-mochi/releases/download/nightly/appcast.xml`

Stable remains:

- app name: `cmux Mochi`
- bundle ID: `com.cmux-mochi`
- URL scheme: `cmux`
- Sparkle feed: `https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml`

## Download a branch nightly artifact

Branch nightly runs upload an Actions artifact instead of publishing the rolling
nightly release tag.

Example from the first green M4 proof on this branch:

```bash
gh run download 28604268708 \
  --repo mochiexists/cmux-mochi \
  --name cmux-nightly-790d6ec
```

The artifact is also visible on the run page:

```text
https://github.com/mochiexists/cmux-mochi/actions/runs/28604268708
```

GitHub downloads Actions artifacts as a zip; unzip it to get the signed and
notarized DMG.

## Branch nightly proof

Use this before merging release-pipeline changes or UI changes intended to ride
the release:

```bash
gh workflow run nightly.yml \
  --repo mochiexists/cmux-mochi \
  --ref <branch> \
  -f force=true \
  -f runner=m4-signing-runner
```

Expected result on a branch:

- `decide` runs on GitHub-hosted `ubuntu-24.04`.
- `build-sign-notarize-nightly` runs on the self-hosted M4 signing lane.
- Release build uses `scripts/build-release-universal.sh`.
- The app and Ghostty helper are universal (`arm64` + `x86_64`).
- The app and DMG are signed, notarized, stapled, and verified.
- Branch artifact upload succeeds.
- Publishing steps are skipped because this is not `main`.

Do not treat this as an auto-update proof. It proves the build/sign/notarize
pipeline and artifact shape. Auto-update is proven by the main nightly publish.

## Main nightly publish

Only run this after the branch changes are on `main`.

```bash
gh workflow run nightly.yml \
  --repo mochiexists/cmux-mochi \
  --ref main \
  -f force=true \
  -f runner=m4-signing-runner
```

Expected result on `main`:

- the workflow moves the rolling `nightly` tag to the built commit;
- the GitHub prerelease `nightly` gets the DMG, immutable DMG, appcast, and
  remote-daemon assets;
- the baked appcast URL points at the fork's GitHub release, not `files.cmux.com`.

Download URL after publish:

```text
https://github.com/mochiexists/cmux-mochi/releases/download/nightly/cmux-nightly-macos.dmg
```

## Stable release

Stable releases use the tag workflow, not `workflow_dispatch`.

Before tagging:

```bash
./scripts/release-pretag-guard.sh
```

Use the build form when Swift, project, or release workflow changes are involved:

```bash
./scripts/release-pretag-guard.sh --build
```

Then tag and push:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo mochiexists/cmux-mochi
```

Never reuse a failed release tag. Cut the next patch version instead.

## Guardrails learned from the M4 proof

These are release invariants, not preferences:

- `gh` must be authenticated as an account with admin/write access to
  `mochiexists/cmux-mochi`; account drift to a read-only account causes 403s on
  dispatch/cancel.
- The tiny `decide` job must stay on GitHub-hosted Ubuntu so M4 dispatches do
  not queue behind fork-specific Linux runner labels.
- Nightly and stable signing/notarization jobs must have enough timeout for the
  full universal Release build plus Apple notarization waits. Stable and nightly
  currently use 75 minutes.
- Nightly identity injection must produce `cmux Mochi NIGHTLY`, not upstream
  `cmux NIGHTLY`, before signing.
- `files.cmux.com` must not appear in fork release/nightly workflows.
- Local fallback `scripts/build-sign-upload.sh` must use
  `scripts/build-release-universal.sh`; bare Release `xcodebuild` does not prove
  the singlefile universal release build.

Focused checks:

```bash
bash tests/test_nightly_universal_build.sh
bash tests/test_ci_release_sdk_lane.sh
bash tests/test_ci_universal_release_settings.sh
python3 tests/test_cli_socket_autodiscovery.py
bash tests/test_start_cmux_profiling.sh
./scripts/fork-overlay-audit.sh
actionlint -shellcheck= .github/workflows/nightly.yml .github/workflows/release.yml .github/workflows/ci.yml
```

## Build time follow-up

The strict Release build is intentionally slow:

- universal `arm64 x86_64`;
- `SWIFT_COMPILATION_MODE=singlefile`;
- `-jobs 1`;
- macOS Release configuration;
- app notarization and DMG notarization.

Those flags caught release-only type-check failures and should stay strict for
release proof. The waste is retrying the whole build when only a later
notarization/publish step failed.

Recommended improvement:

1. Split nightly into a build job and a sign/notarize/publish job.
2. Upload the unsigned universal app plus universal Ghostty helper as an
   internal artifact after the build job.
3. Let sign/notarize/publish retries reuse that artifact.
4. Add a DerivedData cache or stable runner-temp DerivedData path for the
   strict Release build, following the CI `release-build` pattern.

