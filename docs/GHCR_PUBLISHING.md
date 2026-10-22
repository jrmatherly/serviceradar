# Publishing ServiceRadar Images to GHCR with Bazel

This note describes the Bazel-native workflow for building and pushing the
ServiceRadar container images, and how the registry is chosen. The fork
publishes to the GitHub Container Registry (GHCR) by default; any OCI
distribution registry works with the same variables.

## Overview

- Each image in `docker/images/image_inventory.bzl` has a matching `oci_push`
  target. The inventory holds image NAMES only (`serviceradar-core-elx`, ...).
- The registry host and project are stamped in at build time from workspace
  status: `scripts/workspace_status.sh` emits `STABLE_OCI_REGISTRY` and
  `STABLE_OCI_PROJECT` from the `OCI_REGISTRY` and `OCI_PROJECT` environment
  variables, defaulting to `ghcr.io` and `jrmatherly`. `push_targets.bzl`
  expands them into a per-image `repository_file`, so one variable moves every
  image: `OCI_REGISTRY=ghcr.io OCI_PROJECT=acme bazel run --stamp //:push`
  publishes `ghcr.io/acme/serviceradar-core-elx` and friends.
- The canonical aggregate publish target is `//:push`, which delegates to
  `//docker/images:push_all` (`rules_multirun`, `jobs = 0`).
- Tags: every push publishes `latest` and `sha-<commit>` (falling back to
  `sha-dev` without `--stamp`); release pushes add `v<VERSION>`. Extra tags
  are passed at run time: `bazel run --stamp //:push -- --tag v1.2.3`.

## Credentials

In GitHub Actions nothing needs to be configured for GHCR: the workflows use
`github.actor` with `GITHUB_TOKEN` and `permissions: packages: write`. To
publish to another registry, set BOTH secrets `OCI_USERNAME` and `OCI_TOKEN`
and the repository variables `OCI_REGISTRY` and `OCI_PROJECT`. Setting only
one of the two secrets fails the login step on purpose.

Locally:

```bash
export OCI_REGISTRY=ghcr.io
export OCI_PROJECT=<your GitHub owner, lowercase>
export OCI_USERNAME=<github user>
export OCI_TOKEN=<classic PAT with write:packages>

make push_all PUSH_TAG="v$(git describe --tags --always)"
```

`buildbuddy_setup_docker_auth.sh` turns `OCI_USERNAME`/`OCI_TOKEN` into
`~/.docker/config.json` so `rules_oci` can push. Base images are pulled from the
fork's own GHCR mirror (`ghcr.io/<owner>/mirror/...`, populated by
`.github/workflows/base-image-mirror.yml` from the pins in `MODULE.bazel`), so
no other registry credential is needed.

## Registry access from scripts

`scripts/oci_registry.sh` provides `oci_registry_token <repo> [actions]`,
which discovers the token endpoint from the registry's own
`WWW-Authenticate` challenge on `/v2/`. It therefore works against GHCR
(`/token`), Harbor (`/service/token`) and any other distribution-compliant
registry without knowing the path. The sign and verify scripts use it.

GHCR does not serve the OCI 1.1 referrers API (it returns 404), so cosign
signatures live on the `sha256-<digest>.sig` tag. `scripts/verify-oci-publish.sh`
tries the referrers API first and falls back to the tag when the registry
answers 404.

## Command usage

- `make push_all` pushes all images with `latest` and `sha-<commit>`. Set
  `LOCAL_COSIGN_SIGN=1` to also sign and run `make verify_publish`.
- `make push_all PUSH_TAG=v1.2.3` adds an extra tag.
- `make push_all_release` runs `push_all` and `push_wasm_plugins`, both
  signed and verified, for the same tag. It does not publish the Helm chart,
  packages, the managed-agent manifest or the native add-on catalog; the
  formal release is `.github/workflows/release.yml` (see
  `docs/RELEASE_PUBLISHING.md`).
- `bazel build -c opt --config=remote //:images` builds the publishable set.
- `bazel run --stamp //docker/images:core_elx_image_amd64_push -- --tag 1.2.3`
  pushes one image with an extra tag.

On macOS `make push_all` uses `scripts/push_all_images.sh` instead of
`//:push`, because the aggregate `rules_multirun` launcher may try to run a
Linux Python runtime on the host.

## Verification

```bash
make verify_publish
make verify_publish VERIFY_TAG="v$(git describe --tags --always)"
./scripts/verify-oci-publish.sh latest "sha-$(git rev-parse HEAD)"
```

The verifier checks that single-arch repositories publish single manifests,
multi-arch ones publish indexes with `linux/amd64` and `linux/arm64/v8`, a
Cosign signature is present (referrers or tag) and verifies, and runtime
metadata (`Entrypoint`, `Cmd`, `WorkingDir`, selected env) matches the Bazel
image declarations.

Customer-facing verification uses the public key in `docs/cosign.pub`:

```bash
cosign verify --key docs/cosign.pub ghcr.io/jrmatherly/serviceradar-core-elx:v1.2.10
```

Keyless (Sigstore) verification remains possible when a release was signed
that way; see `docs/sigstore/README.md`.
