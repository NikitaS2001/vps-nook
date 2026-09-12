# Releasing

This page is for the project maintainer. A release starts from a clean,
up-to-date `main` and ends only after local publication verification.

## Prepare

1. Ensure the changelog release heading, release notes, upgrade notes, and
   installer release reference describe the same SemVer tag. Replace
   `Unreleased` in that heading with the ISO release date before tagging.
2. Run the complete gate:

   ```bash
   ./scripts/check.sh --release
   ```

3. Confirm the exact commit is on `origin/main` and all required checks passed.
4. Confirm repository release immutability, tag protection, and private
   vulnerability reporting are enabled.

## Tag

Create an annotated SSH-signed SemVer tag locally on the exact green commit,
verify it, and push only that tag. GitHub Actions never creates a release tag
and stores no maintainer signing key.

```bash
git tag -s -m "Release vX.Y.Z" vX.Y.Z <green-main-sha>
git verify-tag vX.Y.Z
git push origin refs/tags/vX.Y.Z
```

Signer rotation requires updating the repository's allowed signers and release
documentation in a reviewed change before creating the new tag.

## Verified draft

The protected `release.yml` workflow verifies the tag and its commit, builds
exactly seven assets, attests every asset with GitHub OIDC, creates a draft,
downloads it, and compares the downloaded bytes:

- `CHANGELOG.md`
- `RELEASE_NOTES.md`
- `SHA256SUMS`
- `UPGRADE.md`
- `install.sh`
- `install.sh.sha256`
- `sbom.spdx.json`

The workflow deliberately leaves the verified release as a draft. A green
workflow is not publication.

## Publish

From the same clean repository, run the local publisher for the exact tag:

```bash
./scripts/publish-release.sh vX.Y.Z
```

The publisher checks the canonical remote, GitHub identity, local/remote tag
object equality, signed-tag contract, protected source commit, and repository
immutability. It rebuilds the assets locally, downloads the draft, verifies
checksums, bytes, and each attestation, then publishes it.

After publication it verifies GitHub's release attestation, confirms the release
is immutable, downloads it again, and compares the published bytes with the
local build. Any failure leaves publication incomplete or reports the exact
manual recovery boundary.

Do not edit an immutable release, move a release tag, upload extra assets, or
publish directly from the workflow UI.

## VPS Nook v2 publication checklist

v2 is currently unreleased. Review validation evidence in the pull request,
finish supported-platform E2E including SSH negative cases, and keep historical
tags/assets untouched. Confirm the `NikitaS2001/vps-nook` workflow and attestation
identity before creating the signed v2.0.0 tag.

Before release, manually dispatch the Weekly workflow. For migration acceptance,
run it twice consecutively against the same commit, including both supported
operating systems and lifecycle/restore; there is no need to wait for the schedule.
Weekly runs on Mondays at 02:17 UTC (Greenwich time).
Verify the draft release assets and exercise the downloaded installer in a
disposable VPS. Only then publish with the existing publisher.

After publication, replace the quickstart preview fence with an executable Bash
fence and the publication marker expected by `scripts/verify-ssot.sh`; remove the
preparation notices from README and Getting started. Supply real HTTP status
evidence via `VERIFY_SSOT_RELEASE_STATUS_FIXTURE` when checking executable release
URLs. Never fabricate successful availability for an unpublished asset.
