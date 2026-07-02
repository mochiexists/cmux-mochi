# Release Checklist

This reference expands the cmux release workflow.

## Default path

Prefer the `/release` command. It should handle:

- choosing the version
- gathering commits since the last tag
- updating `CHANGELOG.md`
- running `./scripts/bump-version.sh`
- committing release metadata
- running `./scripts/release-pretag-guard.sh`
- tagging and pushing

## Version policy

This is a public Mochi fork. Use a patch bump by default for ordinary fork releases, so releases continue as `0.64.162`, `0.64.163`, etc. Use `minor`, `major`, or an explicit version only when intentionally realigning to a larger upstream release base.

The version bump script updates both:

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`

The build number must increase for Sparkle auto-update. If `release-pretag-guard.sh` fails because the build number is not monotonic, run the bump script, commit the build-number bump, and retry the guard.

The version bump script uses the latest published appcast as the version/build baseline so stale local checkouts do not go backwards.

`release-pretag-guard.sh` also runs the fork overlay audit and requires a completed successful
`ci.yml` run on the exact local `HEAD`. Pass `--build` when you want the guard to also run the
local universal Release build. Pass `--skip-ci-check` only for deliberate offline/local release
preparation; it still runs the local checks and prints a warning.

## Changelog

Update `CHANGELOG.md`. The docs changelog page at `web/app/docs/changelog/page.tsx` renders from it, so do not update a separate docs changelog source.

Keep the changelog user-facing. Mention user-visible fixes, behavior changes, and compatibility notes more prominently than internal refactors.

## Tagging

Run before tagging:

```bash
./scripts/release-pretag-guard.sh
```

Manual tag flow:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo mochiexists/cmux-mochi
```

Mochi release runner split:

- `Build GhosttyKit` and `build-ghostty-cli-helper` run on GitHub-hosted `macos-15`.
- `build-sign-notarize` runs on the self-hosted GitHub Actions signing runner label.
- Do not put concrete self-hosted runner host names in public docs, workflows, or logs.
- GhosttyKit archives are published to and downloaded from `mochiexists/ghostty`.
- Do not reuse or force-move a pushed release tag. If the workflow/source needs a fix after a failed tag run, bump and cut the next tag.

## Release asset

The expected release asset is:

```text
cmux-macos.dmg
```

The README download button points to:

```text
releases/latest/download/cmux-macos.dmg
```

If the asset name changes, update every surface that assumes this path.

## Required secrets

Release signing/notarization depends on:

- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

If release automation fails before signing, inspect workflow configuration and version metadata first. If it fails during signing/notarization, inspect the secret availability and Apple account status.
