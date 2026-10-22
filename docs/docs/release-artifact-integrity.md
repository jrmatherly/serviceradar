---
title: Release Artifact Integrity
---

# Release artifact integrity

ServiceRadar product releases use one version identity across every published
artifact. For product version `X.Y.Z`, all of the following must agree:

- Git tag `vX.Y.Z`
- `VERSION` value `X.Y.Z`
- Helm `Chart.yaml` `version` and `appVersion` values `X.Y.Z`
- OCI Helm chart tag `X.Y.Z`
- OCI image semantic tags `vX.Y.Z`
- GitHub release tag `vX.Y.Z`

The release workflow validates this agreement at the tagged commit. It refuses
to publish from an arbitrary branch head, including during manual dispatch.

## Cut a release

Prepare the changelog entry, then use the supported release helper from a clean
release branch:

```bash
scripts/cut-release.sh --version X.Y.Z --dry-run
scripts/cut-release.sh --version X.Y.Z
```

The helper checks both `origin` for `vX.Y.Z` and the OCI chart repository for
chart version `X.Y.Z` before changing release metadata. Both checks fail closed:
if Git or the registry cannot be queried reliably, stop and restore access
instead of bypassing the guard.

Follow the merge and tag-push commands printed by the helper. The release tag
must point to a commit reachable from `staging`. Do not push a release tag until
the release change has merged.

## Retry a failed publication

Use the release workflow's manual dispatch and provide the existing release tag.
The workflow fetches that exact tag, verifies that it is reachable from
`origin/staging`, and revalidates the metadata at the tagged commit. A branch,
commit SHA, missing tag, or value derived from the current `VERSION` file is not
a valid manual release source.

The retry remains subject to artifact immutability. It can complete missing
artifacts, but it cannot replace an OCI chart version that already exists.

## Recover from an occupied version

Treat a published OCI chart version as an immutable audit record, even if no
matching Git tag or GitHub release exists. Deleting a Git tag does not make an
OCI chart version reusable, and operators must not delete or overwrite the chart
to force a release through.

If the requested version is occupied:

1. Leave the existing Git and OCI records intact.
2. Select the next unoccupied product version.
3. Add a changelog entry for that version.
4. Run `scripts/cut-release.sh` again with the new version.

Chart-only versions `1.4.16`, `1.4.17`, and `1.4.18` are known historical
records and must remain reserved. The same rule applies to any future partial
or interrupted release.

## Protect chart publication credentials

By default the release publishes images and the Helm chart to GHCR with the
workflow's `GITHUB_TOKEN` (`packages: write`). A registry with separate
accounts can keep the chart publisher distinct: the protected GitHub `release`
environment may provide

- `CHART_OCI_USERNAME`
- `CHART_OCI_TOKEN`

which the chart step prefers over the general `OCI_USERNAME` / `OCI_TOKEN`
pair. The chart account should have only the permissions needed to pull and
push the chart repository; do not grant delete authority. Protect the GitHub
environment with release approvals and the repository's release tag policy.

The general image-publisher credentials used by ordinary CI must not have push
or delete authority for the product chart repository when the registry can
distinguish them. Developer and validation paths may receive read-only access
when they need to check whether a chart version exists.

These registry and GitHub access controls are deployment configuration. Verify
them whenever credentials are rotated; the workflow's separate secret names
prevent accidental reuse but cannot replace registry-side authorization.
