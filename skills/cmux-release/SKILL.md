---
name: cmux-release
description: "cmux release workflow, version bumping, changelog updates, pretag guard, release tags, and release asset expectations. Use when preparing or troubleshooting a cmux release."
---

# cmux Release

Use the `/release` command to prepare a new release. This will:

1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, run `./scripts/release-pretag-guard.sh`, tag, and push

## Version bumping

```bash
./scripts/bump-version.sh
./scripts/bump-version.sh patch
./scripts/bump-version.sh major
./scripts/bump-version.sh 1.0.0
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The build number is auto-incremented and is required for Sparkle auto-update to work.

Before creating a release tag, run:

```bash
./scripts/release-pretag-guard.sh
```

If it fails, run `./scripts/bump-version.sh`, commit the build-number bump, then retry tagging.

Manual release steps if not using the command:

```bash
./scripts/release-pretag-guard.sh
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo mochiexists/cmux-mochi
```

## Notes

- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `cmux-macos.dmg` attached to the tag.
- README download button points to `releases/latest/download/cmux-macos.dmg`.
- Bump the minor version for updates unless explicitly asked otherwise.
- Update `CHANGELOG.md`; docs changelog is rendered from it.
- Mochi release runner split: GhosttyKit and the Ghostty CLI helper run on GitHub-hosted `macos-15`; app build/sign/notarize runs on the self-hosted GitHub Actions runner `cmux-mochi-m4pro`.
- GhosttyKit archives are published to and downloaded from `mochiexists/ghostty`.
- Never reuse or move an already-pushed release tag. If workflow/source changes are needed after a failed tag run, bump and cut the next tag.

## Detailed reference

- Read [references/release-checklist.md](references/release-checklist.md) for a more detailed release checklist and common failure handling.
