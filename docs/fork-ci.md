# Fork CI

`jrmatherly/serviceradar` is a fork of `carverauto/serviceradar` that deviates
from upstream and adopts upstream pull requests selectively. Everything under
`.github/`, plus `buildbuddy.yaml`, `build/rbe/BUILD`, `build/ci/*.py` and
`scripts/ci/`, is the fork's own CI. Upstream changes to those paths are
hand-ported, never merged as-is (see "Porting upstream workflow changes").

The acceptance check is `scripts/ci/check-fork-ci.sh`: actionlint (with
shellcheck) must be clean, and no non-comment line in the paths above may name
upstream infrastructure (`registry.carverauto.dev`, `carverauto.buildbuddy.io`,
the self-hosted runner labels, Harbor or OpenBao secrets). Run it before every
commit that touches CI.

## Services and their free tiers

All of the fork's CI runs on services that are free for a public repository.
Researched 2026-10-21. Verified the same day: `bazel-remote-smoke.yml` built
`//build/ci:verify_git_metadata` on BuildBuddy executors (`remote, disk-cache,
remote-cache`) using the fork's executor image, and a `v*` tag pushed with
`PUBLISH_ENABLED` unset skipped every release, add-on and Wasm job and created
no release while `source-security` finished in under three minutes.

The org created on app.buildbuddy.io also answers at `matherly.buildbuddy.io`
(the Workflows status links point there); `remote.buildbuddy.io` with the org
API key is what the smoke test used and is the default endpoint.

| Service | Free tier for a public repo | Used for |
| --- | --- | --- |
| GitHub Actions, standard hosted runners | Free. Linux 4 vCPU, 16 GiB, about 14 GB disk. Larger runners are always billed. | Every workflow job (`ubuntu-24.04`, `macos-15`, `windows-latest`). |
| BuildBuddy Cloud, Personal plan | Free for open source: remote execution up to 80 Linux cores, 100 GB cache transfer per month, 10 users, unlimited builds. Custom executor images allowed; `network=host` not available; Mac executors not included. Hosted workflow runners use BuildBuddy's named Ubuntu images; their resource caps are not published. | Bazel remote execution and cache for every Bazel job; the BazelCI unit sweep. |
| GitHub Container Registry | Free for public packages; bandwidth currently free. No OCI referrers API (cosign signatures live on the `.sig` tag). | Images, Helm chart, native add-on and Wasm plugin OCI artifacts, the RBE executor image. |
| Sigstore public-good instance | Free, production use supported. | Optional keyless signing override only; the product verifies with a committed public key. |
| GitHub Pages | Free: 1 GB site, 100 GB/month soft bandwidth. | `docs-pages.yml` once `DOCS_PAGES_ENABLED` is set and Pages is enabled. |
| npm trusted publishing | Free for public packages, but `@carverauto/serviceradar-cli` is owned by upstream. | `cli-npm-publish.yml`, blocked until the rebrand renames the package. |
| hex.pm | Free, but `palisade` is owned by upstream. | `palisade-publish.yml`, blocked until the rebrand. |
| Apple notarization | Not free (Apple Developer Program). | Signed macOS installers, off until `MACOS_SIGNING_ENABLED`. |

## Fork contract: variables and secrets

Repository variables unless marked. Secrets live in the `release` environment
except `BUILDBUDDY_API_KEY`, which the smoke test and non-release Bazel jobs
also need at repository level.

| Name | Kind | Default when unset | Used by |
| --- | --- | --- | --- |
| `OCI_REGISTRY` | var | `ghcr.io` | release, publish-oci, native-addons, wasm-plugins, external-wasm-plugin, image-security, buildbuddy.yaml |
| `OCI_PROJECT` | var | `github.repository_owner` | same |
| `OCI_CHART_REPOSITORY` | var | `<owner>/charts` | release |
| `OCI_USERNAME` / `OCI_TOKEN` | secret | `github.actor` / `GITHUB_TOKEN`; set both or neither | same as `OCI_REGISTRY` |
| `CHART_OCI_USERNAME` / `CHART_OCI_TOKEN` | secret | falls back to `OCI_*` | release (Helm chart) |
| `PUBLISH_ENABLED` | var | unset: every tag-triggered publish job is skipped | release, native-addons, wasm-plugins, cli-npm-publish, palisade-publish, source-security upload |
| `DOCS_PAGES_ENABLED` | var | unset: Pages deploy skipped, docs build still runs | docs-pages |
| `MACOS_SIGNING_ENABLED` | var | unset: signed macOS jobs skipped, unsigned build still runs | release, agent-platform-packages |
| `LARGE_INGESTION_GATE_ENABLED` | var | unset: release does not wait for the BazelCI gate | release |
| `DEMO_RELEASE_BRANCH_ENABLED` | var | unset: `demo/prod-release` is not advanced | release |
| `OPENBAO_SIGNING_ENABLED` | var | unset: cosign uses `COSIGN_PRIVATE_KEY` | release, publish-oci, native-addons, wasm-plugins, external-wasm-plugin |
| `BAZEL_REMOTE_ENABLED` | var | `true`; anything else makes Bazel jobs fail fast | all Bazel jobs |
| `BUILDBUDDY_ENDPOINT` | var | `remote.buildbuddy.io` | all Bazel jobs |
| `BUILDBUDDY_APP_URL` | var | `https://app.buildbuddy.io` | all Bazel jobs, ingestion gate |
| `BUILDBUDDY_API_KEY` | secret | none; required | all Bazel jobs (`BUILDBUDDY_ORG_API_KEY` in the release environment overrides it) |
| `COSIGN_PRIVATE_KEY` / `COSIGN_PASSWORD` | secret | none; required for any signed publish | signing jobs |
| `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` | secret | none; required | release, publish-oci, native-addons |
| `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY` / `_KEY_ID` | secret | none; required | wasm-plugins, external-wasm-plugin |
| `PLUGIN_UPLOAD_SIGNING_SIGNER` | secret | the key id | same |
| `PLUGIN_ORG` | var | `github.repository_owner` | external-wasm-plugin |
| `MACOS_*` (8 secrets) | secret | none | release, agent-platform-packages |
| `HEX_API_KEY` | secret | none | palisade-publish |
| `SIGSTORE_*`, `COSIGN_CERTIFICATE_*`, `COSIGN_KEYLESS` | secret | unset | keyless override only |
| `AGENT_TEST_ARTIFACT_BASE_URL`, `EXTERNAL_PLUGIN_GITHUB_*` | var / secret | upstream, unchanged | native-addons, external-wasm-plugin |

Job-level `if:` reads repository and organisation variables only; a variable
set on the `release` environment does not open a gate.

## Owner actions

1. BuildBuddy: create an org API key with executor permission and set it as
   the repository secret `BUILDBUDDY_API_KEY`; link the repository on the
   Workflows page. Dispatch `bazel-remote-smoke.yml` to prove it.
2. Generate the signing keys and put the private halves in the `release`
   environment; commit the public halves (`docs/cosign.pub`,
   `elixir/web-ng/config/config.exs`, both Helm values files,
   `go/pkg/agent/release_signing_key.txt`, the `agentReleasePublicKey` values).
   `cosign generate-key-pair` produces the cosign pair. The agent and Wasm keys
   are Ed25519: the agent key secret is the base64 (or hex) seed or 64-byte
   private key, and the public key is what
   `bazel run //tools/go/derive_agent_release_public_key` prints with the secret
   in the environment.
3. Create the `release` environment and allow deployments from `v*` tags AND the
   `staging` branch: the dispatch-only publish jobs (publish-oci, external-wasm-plugin,
   the macOS signing rehearsal, the agent test artifact) run from `staging` under
   that environment.
4. Set `PUBLISH_ENABLED=true` when a release should actually publish.
5. Optional: enable Pages, Apple Developer Program.

## Workflows

| File | Trigger | Purpose | State |
| --- | --- | --- | --- |
| `golangci-lint.yml` | push, PR | golangci-lint, buf lint and breaking, go mod tidy | kept |
| `elixir-quality.yml` | push, PR (paths) | mix format and credo per touched project; db checks | kept |
| `elixir-dependency-audit.yml` | schedule, PR/push (paths), dispatch | hex and deps audit | kept |
| `helm-lint.yml` | push, PR (paths) | helm lint, renders, chart-default guards | kept |
| `migration-collision-guard.yml` | push, PR | Ecto migration collisions against latest staging | kept |
| `native-addon-version-bumps.yml` | push, PR | changed add-on must bump its version | kept |
| `rust-checks.yml` | push, PR (paths), schedule | cargo clippy, cargo audit | kept |
| `secret-scan.yml` | PR, push, schedule, dispatch | gitleaks | kept |
| `source-security.yml` | push, dispatch | Syft SBOM and OSV scan; release upload gated | kept, gated |
| `tests-fingerprint-licensing.yml` | PR, push (paths) | netprobe fingerprint licences (installs protoc) | kept |
| `web-ng-lint.yml` | push, PR (paths) | ESLint and Vitest for web-ng assets | kept |
| `release.yml` | `v*` tags, dispatch | the release: images, chart, packages, installers, GitHub release | kept, gated |
| `publish-oci.yml` | dispatch | images to the registry on demand | kept |
| `native-addons.yml` | `v*` tags, dispatch | native add-on catalog | kept, gated |
| `wasm-plugins.yml` | `v*` tags | Wasm plugin catalog | kept, gated |
| `external-wasm-plugin.yml` | dispatch | rebuild and publish an external plugin repo under `PLUGIN_ORG` | kept |
| `image-security.yml` | dispatch (from release) | Syft/OSV scan of published images | kept |
| `agent-platform-packages.yml` | dispatch | macOS and Windows installers; signing rehearsal gated | kept, gated |
| `cli-npm-publish.yml` | `cli-v*` tags, dispatch | npm CLI publish; dry run always allowed | kept, gated, blocked by package name |
| `palisade-publish.yml` | `palisade-v*` tags | hex publish | kept, gated, blocked by package name |
| `docs-pages.yml` | push (docs paths), dispatch | Docusaurus build; Pages deploy gated | kept, gated |
| `inspect-oidc.yml` | dispatch | dump the Actions OIDC token | kept |
| `bazel-remote-smoke.yml` | dispatch, PR (paths) | proves BuildBuddy RBE and the executor image | new, replaces `arc-smoke.yml` |
| `rbe-executor-image.yml` | dispatch | builds `docker/Dockerfile.rbe` and pushes it to GHCR | new |
| `base-image-mirror.yml` | dispatch, PR (pin paths) | copies every `MODULE.bazel` base image into `ghcr.io/<owner>/mirror/` by digest | new |

Deleted: `arc-smoke.yml` (self-hosted pool smoke test), `.github/actionlint.yaml`
(self-hosted label list), `.github/FUNDING.yml` (upstream maintainer's sponsor
link), `.github/actions/macos-release-keychain` is kept (release and the
installers use it).

## buildbuddy.yaml

| Action | State |
| --- | --- |
| `BazelCI` | enabled: PR unit sweep on a BuildBuddy-hosted `ubuntu-24.04` runner with `--config=remote`; resource requests 7 CPU / 28 GB / 40 GB were accepted by the hosted runner. The free tier caps a workflow run at 1 hour (`--timeout_reason=free_tier_limit` in the runner's command line). |
| `BazelCI Core Integration`, `BazelCI Web-NG DB`, `LargeIngestionGate`, `SchemaTemplateQualification`, `SrqlParity`, `GodViewAcceptance`, `WebNgDbDiagnostic`, `WorldWorkerScale`, `IntegrationBenchmark*`, `Elixir Quality (daily)` | disabled (no triggers): they need self-hosted executor pools and in-cluster fixtures (CNPG, Dgraph, StarRocks). Their definitions are kept for manual dispatch where that infrastructure exists. |

`.bazelrc`'s `build:ci` profile still assumes the node-volume cache paths of
upstream's workflow executors; the fork's BazelCI uses `--config=remote`.

## Porting upstream workflow changes

1. Apply the upstream diff by hand to the fork's copy of the file.
2. Re-apply the contract: `runs-on: ubuntu-24.04`, `OCI_*` from variables,
   the `Configure Bazel remote execution` step, `PUBLISH_ENABLED` and the other
   gates, `OPENBAO_SIGNING_ENABLED` around any `prepare-openbao-cosign-env.sh`.
3. Never add `arc-runner-set`, `serviceradar-signing`, `HARBOR_*`,
   `self_hosted: true`, `pool:`, or a `carverauto` hostname.
4. A new upstream workflow is classified (lint/test, publish, infrastructure)
   and added to the table above with its gates.
5. Run `scripts/ci/check-fork-ci.sh`; it must print nothing and exit 0.

## Known blockers

- npm and hex package names belong to upstream; publishing waits for the rebrand.
- Signed macOS installers need the Apple Developer Program.
- Base images are mirrored into `ghcr.io/<owner>/mirror/...` by
  `base-image-mirror.yml`; a pin bump in `MODULE.bazel` must be mirrored
  (the workflow runs on PRs that touch the pins) before it can build.
- The BazelCI integration actions need fixture infrastructure the fork does
  not have.
- `docs/docusaurus.config.ts` and `docs/static/CNAME` still name upstream's
  domain and organisation; enabling Pages before the rebrand would publish
  under them.
