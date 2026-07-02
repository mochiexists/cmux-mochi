---
name: cmux-release
description: "cmux release workflow, version bumping, changelog updates, pretag guard, release tags, and release asset expectations. Use when preparing or troubleshooting a cmux release."
---

# cmux Release

Use the `/release` command to prepare a new release. This will:

1. Determine the new version (bumps patch by default for this Mochi fork)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, run `./scripts/release-pretag-guard.sh`, tag, and push

## Version bumping

```bash
./scripts/bump-version.sh          # bump patch (0.64.161 -> 0.64.162)
./scripts/bump-version.sh patch    # bump patch explicitly
./scripts/bump-version.sh minor    # deliberate upstream-base jump only
./scripts/bump-version.sh major
./scripts/bump-version.sh 1.0.0
```

This is a public Mochi fork. Between major upstream rebases, keep shipping fork patch releases as `0.64.162`, `0.64.163`, etc. Use `minor` or an explicit version only when intentionally realigning to a larger upstream release base.

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The build number is auto-incremented and is required for Sparkle auto-update to work. The bump script also uses the latest published appcast as the version/build baseline so stale local checkouts do not go backwards.

Before creating a release tag, run:

```bash
./scripts/release-pretag-guard.sh
```

The guard checks Sparkle build monotonicity, the fork overlay audit, and a completed successful
`ci.yml` run on the exact local `HEAD`. Use `./scripts/release-pretag-guard.sh --build` to also
run the local universal Release build. Use `--skip-ci-check` only for deliberate offline/local
release preparation; it prints a warning and still runs the local checks.

If it fails on build monotonicity, run `./scripts/bump-version.sh`, commit the build-number bump,
then retry tagging. If it fails on the CI check, run CI for the exact commit before tagging.

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
- Bump patch by default for fork releases unless explicitly doing an upstream-base jump.
- Update `CHANGELOG.md`; docs changelog is rendered from it.
- Mochi release runner split: GhosttyKit and the Ghostty CLI helper run on GitHub-hosted `macos-15`; app build/sign/notarize runs on the self-hosted GitHub Actions signing runner label.
- Do not put concrete self-hosted runner host names in public docs, workflows, or logs.
- GhosttyKit archives are published to and downloaded from `mochiexists/ghostty`.
- Never reuse or move an already-pushed release tag. If workflow/source changes are needed after a failed tag run, bump and cut the next tag.

## Detailed reference

- Read [references/release-checklist.md](references/release-checklist.md) for a more detailed release checklist and common failure handling.
