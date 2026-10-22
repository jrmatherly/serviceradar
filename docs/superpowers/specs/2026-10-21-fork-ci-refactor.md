# Fork CI refactor: spec (rev 2, 2026-10-21)

`jrmatherly/serviceradar` is a fork of `carverauto/serviceradar`. `.github/`
and `buildbuddy.yaml` become the fork's own. Upstream's 23 workflows are KEPT
and refactored so the fork's CI runs entirely on services with a free tier for
public repositories, and nothing names upstream infrastructure. The rebrand
(Go module path, image and package names) is out of scope.

Rev 1 assumed local Bazel on hosted runners and keyless signing. A review and
a read of `docs/RELEASE_PUBLISHING.md`, `docs/GHCR_PUBLISHING.md`, `BUILD.md`
and `docs/SBOM.md` showed both were wrong. Rev 2 replaces them with BuildBuddy
Cloud's free plan and a fork-owned signing keypair.

## Services and their free tiers (researched 2026-10-21)

| Service | Free tier for a public repo | Verified how | Enough? |
| --- | --- | --- | --- |
| GitHub Actions, standard hosted runners | Free. Linux 4 vCPU, 16 GiB, ~14 GB disk. Larger runners are always billed. | docs.github.com billing page | Yes for lint/test and as the publish driver. Not for building `//...` locally. |
| BuildBuddy Cloud, Personal plan | Free "for small teams and open source projects": RBE up to 80 Linux cores, 100 GB cache transfer, 10 users, unlimited builds. Custom `container-image` allowed; `network=host` not available in cloud; Mac executors not included. Workflows (BazelCI) hosted runners: named Ubuntu images only, default 3 CPU / 8 GB / 20 GB, `resource_requests` configurable with no published cap; plan inclusion not stated on the pricing page. | buildbuddy.io/pricing, docs rbe-platforms, workflows-config | Yes for RBE and cache behind the GitHub publish workflows, pending the probe in Task 2. Partial for BazelCI. The 100 GB/month transfer is the number to watch. |
| GitHub Container Registry | Free for public packages, bandwidth currently free. Standard `/token` auth. No OCI referrers API (probe: `/v2/<repo>/referrers/<digest>` returns 404 MANIFEST_UNKNOWN). Harbor's `/service/token` path returns 303. | docs.github.com packages billing; live curl | Yes, with a registry-neutral token helper and cosign's tag-based signature fallback. |
| Sigstore public-good instance | Free, production use supported, 99.5% SLO, 100 KB Rekor upload limit. | docs.sigstore.dev | Optional. The product pins a cosign public key, so key-based signing is the primary path. |
| GitHub Pages | Free for public repos: 1 GB site, 100 GB/month soft bandwidth, 10 builds/hour (not for Actions deploys). | docs.github.com pages limits | Yes. Owner must enable Pages and the docs config still names upstream's domain. |
| npm trusted publishing | Free for public packages. `@carverauto/serviceradar-cli` is owned by upstream's maintainer. | npm registry API | Blocked until rebrand renames the package. Gated off. |
| hex.pm | Free. `palisade` is owned by upstream's maintainer. | hex.pm API | Blocked until rebrand. Gated off. |
| Docker Hub | Anonymous 100 pulls/6 h per IP (probe); a free account token raises it. Needed for one base image. | live curl | Yes with `DOCKERHUB_*` secrets from a free account. |
| Apple notarization | Not free (Apple Developer Program). | known | macOS installer jobs gated off until the owner enrols. |
| Windows installers | `windows-latest` hosted runner, free for public repos. | docs.github.com | Yes. |

## Decisions

1. **Registry: GHCR.** `vars.OCI_REGISTRY` defaults to `ghcr.io`, `vars.OCI_PROJECT`
   to the repository owner. Auth is `github.actor` + `GITHUB_TOKEN` with
   `packages: write` unless `secrets.OCI_USERNAME`/`OCI_TOKEN` are set. The
   image repositories are derived in Bazel from stamped workspace status
   (`STABLE_OCI_REGISTRY`, `STABLE_OCI_PROJECT`) via rules_oci's `repository_file`,
   so `image_inventory.bzl` carries names only.
2. **Bazel: BuildBuddy Cloud free plan, on by default once probed.** The publish
   workflows write `.bazelrc.remote` with `remote.buildbuddy.io` endpoints, the
   API key, the fork's executor image and `network=off`, using `build:remote_base`
   and `build:cache_only` prefixes so they override `.bazelrc`. `BAZEL_REMOTE_ENABLED`
   stays as a kill switch. There is no local-Bazel publish path.
3. **Executor image: fork-built.** `docker/Dockerfile.rbe` is built on a hosted
   runner and pushed to `ghcr.io/<owner>/serviceradar-rbe-executor`. `build/rbe/BUILD`
   points at it and drops `dockerNetwork: host`.
4. **Signing: fork-owned cosign keypair, key-based.** The product verifies
   first-party plugins against a committed public key in four places, so keyless
   would break it. OpenBao is gated behind `OPENBAO_SIGNING_ENABLED`; when off,
   `COSIGN_PRIVATE_KEY`/`COSIGN_PASSWORD` secrets are used. The four committed
   copies of the public key are replaced in one commit. Keyless stays available
   as the documented override.
5. **Agent release key: fork-owned Ed25519 pair.** Public half committed to
   `go/pkg/agent/release_signing_key.txt`, private half in the `release` environment.
6. **Runners: GitHub-hosted only.** `arc-smoke.yml` becomes `bazel-remote-smoke.yml`,
   a dispatchable RBE smoke test. 22 upstream files keep their names.
7. **BazelCI (`buildbuddy.yaml`): keep the unit sweep, disable the rest.** The
   `BazelCI` action runs on BuildBuddy-hosted Linux workflow runners (no
   `self_hosted`, no `pool`, named Ubuntu image). The two integration actions and
   every action that reaches `*.svc.cluster.local` or `*.carverauto.dev` fixtures
   lose their triggers (manual only) and are listed as blocked.
8. **PR #1 is closed.** New branch `fork-ci-refactor` from upstream `staging`.

## Fork contract (variables and secrets)

Repository variables unless marked. Secrets live in the `release` environment
except `BUILDBUDDY_API_KEY` and `DOCKERHUB_*`, which lint-free publish jobs and
the smoke test also need at repository level.

| Name | Kind | Default when unset | Used by |
| --- | --- | --- | --- |
| `OCI_REGISTRY` | var | `ghcr.io` | release, publish-oci, native-addons, wasm-plugins, external-wasm-plugin, image-security, buildbuddy.yaml |
| `OCI_PROJECT` | var | `github.repository_owner` | same |
| `OCI_CHART_REPOSITORY` | var | `<owner>/charts` | release |
| `OCI_USERNAME` / `OCI_TOKEN` | secret | `github.actor` / `GITHUB_TOKEN` | same as OCI_REGISTRY |
| `BAZEL_REMOTE_ENABLED` | var | `true` after Task 2 sets it; unset = Bazel jobs fail fast with a message | all Bazel jobs |
| `BUILDBUDDY_ENDPOINT` | var | `remote.buildbuddy.io` | all Bazel jobs |
| `BUILDBUDDY_APP_URL` | var | `https://app.buildbuddy.io` | BES results URL, ingestion gate |
| `BUILDBUDDY_API_KEY` | secret | none; required | all Bazel jobs |
| `RBE_EXECUTOR_IMAGE` | var | `ghcr.io/<owner>/serviceradar-rbe-executor:<tag in build/rbe/BUILD>` | rbe-executor-image.yml publishes it; build/rbe/BUILD consumes the committed value |
| `PUBLISH_ENABLED` | var | unset = tag-triggered publish jobs skipped | release, native-addons, wasm-plugins, cli-npm-publish, palisade-publish |
| `DOCS_PAGES_ENABLED` | var | unset = Pages deploy skipped (build still runs) | docs-pages |
| `MACOS_SIGNING_ENABLED` | var | unset = signed macOS jobs skipped (unsigned build still runs) | release, agent-platform-packages |
| `LARGE_INGESTION_GATE_ENABLED` | var | unset = release does not wait for the BazelCI gate | release |
| `OPENBAO_SIGNING_ENABLED` | var | unset = cosign uses `COSIGN_PRIVATE_KEY` | release, publish-oci, native-addons, wasm-plugins, external-wasm-plugin |
| `COSIGN_PRIVATE_KEY` / `COSIGN_PASSWORD` | secret | none; required for any signed publish | same |
| `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` | secret | none; required for release, publish-oci, native-addons | same |
| `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY` / `_KEY_ID` / `_SIGNER` | secret | none; required for wasm-plugins and external-wasm-plugin | same |
| `PLUGIN_ORG` | var | `github.repository_owner` | external-wasm-plugin |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | secret | anonymous pulls (100/6 h) | release, publish-oci, buildbuddy.yaml |
| `MACOS_*` (8) | secret | none | release, agent-platform-packages |
| `HEX_API_KEY` | secret | none | palisade-publish |
| `SIGSTORE_*`, `COSIGN_CERTIFICATE_*`, `COSIGN_KEYLESS` | secret | unset | keyless override only |
| `AGENT_TEST_ARTIFACT_BASE_URL`, `EXTERNAL_PLUGIN_GITHUB_*` | var / secret | upstream, unchanged | native-addons, external-wasm-plugin |

Dispatch-only workflows (publish-oci, agent-platform-packages,
external-wasm-plugin, image-security, inspect-oidc, bazel-remote-smoke,
rbe-executor-image) are not gated by `PUBLISH_ENABLED`.

## Owner actions (cannot be automated; the plan names where each is needed)

1. BuildBuddy: create an org API key (Settings -> API keys, with executor
   permission), link the GitHub repo on the Workflows page, note the plan shown
   under Settings -> Organization. Needed by Task 2.
2. Set `BUILDBUDDY_API_KEY` (repo secret), `BAZEL_REMOTE_ENABLED=true` after
   Task 2's smoke run passes.
3. Generate keys and set secrets (commands in Task 7): cosign keypair, agent
   Ed25519 keypair, Wasm upload-signing Ed25519 keypair.
4. Create the `release` environment with a `v*` tag deployment rule.
5. Optional: Docker Hub free account token; enable Pages; Apple Developer Program.

## Acceptance

- `scripts/ci/check-fork-ci.sh` exits 0: actionlint clean (shellcheck included)
  and no non-comment line under `.github/`, `buildbuddy.yaml`, `.bazelrc`,
  `build/rbe/BUILD` or `build/ci/*.py` matches `registry\.carverauto\.dev`,
  `carverauto\.buildbuddy\.io`, `cache-proxy\.carverauto\.dev`, `serviceradar-signing`,
  `arc-runner-set`, `HARBOR_`, `OPENBAO_ADDR: https://openbao`, `hashivault://cosign-release`,
  `github-signing-runner`, `svc\.cluster\.local`, or `mfreeman`.
- 22 of the 23 upstream workflow files exist under their original names, plus
  `bazel-remote-smoke.yml` and `rbe-executor-image.yml`.
- The 9 lint/test workflows that trigger on a pull request are green on the PR.
- `bazel-remote-smoke.yml` dispatched on the PR branch builds
  `//build/ci:verify_git_metadata` with `--config=remote` on BuildBuddy and the
  invocation link in the step summary opens.
- `rbe-executor-image.yml` has pushed the executor image to GHCR and the smoke
  run used it (the BuildBuddy invocation shows the fork's `container-image`).
- `release.yml` dispatched with `dry_run=true` on a test tag reaches the
  publish job's Bazel build and completes `//:images` on BuildBuddy. Pushing is
  exercised by `publish-oci.yml` with `publish_scope=web-stack-commit-only`.
- Docs that described upstream infrastructure are rewritten: `docs/fork-ci.md`
  (new), `docs/GHCR_PUBLISHING.md`, `docs/RELEASE_PUBLISHING.md`, `docs/SBOM.md`,
  `BUILD.md` (versions), `docs/docs/release-artifact-integrity.md`.

## Out of scope

- Rebrand: module path `github.com/carverauto/...`, `@carverauto/serviceradar-cli`,
  `palisade`, image names, `docs/docusaurus.config.ts` `organizationName` and
  `docs/static/CNAME`, `.github/.testcoverage.yml` `local-prefix`.
- `MODULE.bazel` base-image pulls from `registry.carverauto.dev/mirror/...`
  (anonymously pullable today; probe `curl -fsS https://registry.carverauto.dev/service/token?service=harbor-registry&scope=repository:mirror/library/alpine:pull`).
  Mirroring them to GHCR is a follow-on.
- The in-cluster fixture infrastructure BazelCI integration actions need
  (CNPG, Dgraph, StarRocks). Those actions are disabled, not ported.
- `k8s/buildbuddy/`: upstream's self-hosted executor charts. Left in place,
  unused.
- The macOS installer signing path beyond gating it.
