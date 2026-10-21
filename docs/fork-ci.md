# Fork CI (`.github/`)

`jrmatherly/serviceradar` is a fork of `carverauto/serviceradar` that
deviates from upstream and cherry-picks upstream pull requests selectively.
Everything under `.github/` is the fork's own: it is NOT kept in sync with
upstream. When an upstream PR touches `.github/`, hand-port the change
(usually only the lint/test workflows below are relevant) instead of taking
the upstream file as-is.

This file records what was kept, what was removed, and why, as of the
`fork-ci` branch cut from upstream `staging` at `5993ec1043`.

## Ground rules

- Workflows run on GitHub-hosted `ubuntu-24.04` (and nothing else). Upstream
  ran most jobs on `arc-runner-set`, a self-hosted Actions Runner Controller
  pool, and signing jobs on `serviceradar-signing`. The fork has neither.
- Triggers are `pull_request` and `push` against `staging` (the default
  branch), plus `schedule`/`workflow_dispatch` where the job is an audit.
  Upstream's `main` branch does not exist here and was dropped from triggers.
- No publishing. Nothing pushes images, charts, packages, releases or pages.
  Re-pointing publishing at the fork's own registries waits for the rebrand
  (module path and image names), which is a separate task.
- No upstream-only secrets. The removed workflows needed Harbor robot
  credentials for `registry.carverauto.dev`, BuildBuddy API keys, Sigstore
  and cosign material, Apple signing certificates and notary keys, Docker
  Hub, npm and hex.pm tokens. None of those are set on the fork, and the
  kept workflows need none of them.
- Dependabot (`.github/dependabot.yml`) is kept unchanged: weekly `cargo`,
  `gomod` and `github-actions` updates against the default branch, ten open
  PRs per ecosystem, minor/patch action bumps grouped. Nothing in it is
  upstream-specific.
- `.github/actionlint.yaml` was removed with the last self-hosted label.
  `actionlint` runs clean on the tree with its defaults, and now fails on
  any reintroduced `arc-runner-set` label, which is the intent.

## Kept (lint and test), with the fork edits applied

| Workflow | What it gates | Edits |
| --- | --- | --- |
| `elixir-quality.yml` | `mix format` and `mix credo --strict` per touched Mix project (seven-way matrix), `scripts/db` checks, `make verify-proto-elixir` | runner |
| `elixir-dependency-audit.yml` | `mix hex.audit` / `mix deps.audit` daily, and on PRs that touch the audit scripts | runner |
| `golangci-lint.yml` | `make lint-go`, `buf lint`, `buf breaking` against the base branch, `go mod tidy` check | runner |
| `helm-lint.yml` | `helm lint`, template renders and the chart-default guard scripts | runner, comment |
| `migration-collision-guard.yml` | Merges the PR with latest `origin/staging` and fails on colliding Ecto migrations | runner |
| `native-addon-version-bumps.yml` | Diffs base vs HEAD so a changed add-on payload cannot land under an unchanged version | runner, comment |
| `rust-checks.yml` | `cargo clippy` per crate set, `cargo audit` weekly | already `ubuntu-24.04`; triggers trimmed to `staging` |
| `secret-scan.yml` | gitleaks over the PR or push range, full history weekly | runner; push trigger trimmed to `staging` |
| `source-security.yml` | Syft source SBOM plus OSV-Scanner report | runner; see below |
| `tests-fingerprint-licensing.yml` | netprobe fingerprint licence check and Recog additions lint | runner |
| `web-ng-lint.yml` | ESLint and Vitest for `elixir/web-ng/assets` (Bun) | runner |

"runner" means `runs-on: arc-runner-set` became `runs-on: ubuntu-24.04`.
"comment" means a code comment that described the ARC runner was reworded;
no behaviour change.

`source-security.yml` changed more than the runner. Upstream ran it on
`push` to `main`/`staging` and on `v*` tags, and on a tag it waited for the
GitHub release that `release.yml` creates and attached the bundle to it via
`scripts/upload-forgejo-release-asset.sh`. With `release.yml` gone there is
no release to attach to, so the tag trigger, the `tag` dispatch input, the
wait/upload steps and the `contents: write` permission were removed. It now
runs on `pull_request` and `push` to `staging`, weekly, and on dispatch, and
uploads the bundle as a workflow artifact named `serviceradar-source-security`.

Three gates upstream relies on are NOT GitHub workflows and are unchanged by
this work: the Bazel build/test sweep, the Elixir unit shards and the daily
compile/xref/dialyzer run all live in `buildbuddy.yaml` (BuildBuddy BazelCI).
The fork has no BuildBuddy org, so those do not run here. The comments in
`elixir-quality.yml` and `native-addon-version-bumps.yml` that say "BazelCI
covers X" describe upstream, not the fork. Covering that gap is a follow-up,
not part of this change.

Branch protection is also the fork's own. Upstream's required checks include
the seven `Elixir Quality (...)` job names; set the fork's required checks
from the job names in the kept workflows, not from upstream's settings.

## Removed

### Publish / release (10 files)

| Workflow | Trigger | What it published | Upstream-only dependencies |
| --- | --- | --- | --- |
| `release.yml` | `v*` tags, dispatch | GitHub release, container images, macOS and Windows installers, Helm chart | `serviceradar-signing` runner, Harbor, BuildBuddy, Sigstore/cosign, Apple signing and notary secrets, Docker Hub, `.github/actions/macos-release-keychain` |
| `publish-oci.yml` | dispatch | Container images to `registry.carverauto.dev` | `serviceradar-signing`, Harbor, BuildBuddy, Sigstore/cosign, Docker Hub |
| `native-addons.yml` | `v*` tags, dispatch | Native add-on catalogs as OCI artifacts | `serviceradar-signing`, Harbor, BuildBuddy, Sigstore/cosign, agent release signing key |
| `wasm-plugins.yml` | `v*` tags | Wasm plugins as OCI artifacts | `serviceradar-signing`, Harbor, BuildBuddy, `GOPRIVATE=github.com/carverauto/*` |
| `external-wasm-plugin.yml` | dispatch | Rebuilds and publishes a `carverauto/serviceradar-plugin-*` repo | `arc-runner-set` + `serviceradar-signing`, Harbor, Sigstore/cosign, read token for carverauto repos |
| `agent-platform-packages.yml` | dispatch | macOS pkg and Windows MSI installers, signing rehearsal | BuildBuddy, Apple signing and notary secrets, `macos-release-keychain` action |
| `cli-npm-publish.yml` | `cli-v*` tags, dispatch | `@carverauto/serviceradar-cli` to npm with provenance | npm trusted publisher bound to `carverauto/serviceradar` |
| `palisade-publish.yml` | `palisade-v*` tags | `palisade` package to hex.pm | `HEX_API_KEY` |
| `docs-pages.yml` | push to `staging`/`main` touching `docs/**` | Docusaurus site to GitHub Pages | Pages enabled for the upstream repo |
| `image-security.yml` | dispatch (from `release.yml`) | Syft/Grype scan of published images, attached to the release | Harbor credentials, images that only exist in `registry.carverauto.dev` |

Also removed with them: `.github/actions/macos-release-keychain/` (used only
by `release.yml` and `agent-platform-packages.yml`) and `.github/FUNDING.yml`
(the upstream maintainer's sponsor link; a fork should not show it).

### carverauto infrastructure (2 files)

| Workflow | Why |
| --- | --- |
| `arc-smoke.yml` | Smoke test for the `arc-runner-set` self-hosted pool. No such pool here. |
| `inspect-oidc.yml` | Dumps the Actions OIDC token on `arc-runner-set` to debug the Sigstore trust setup. No Sigstore setup here. |

## Porting upstream workflow changes

When an upstream PR changes a file under `.github/workflows/`:

1. If the file is in the "Removed" tables, ignore the change. Publishing
   comes back only with the rebrand, and will be written fresh then.
2. If the file is in the "Kept" table, apply the upstream diff by hand and
   re-apply the fork edits listed for it (runner, triggers). Do not add
   `arc-runner-set`, `serviceradar-signing`, `main` branch triggers, or any
   `secrets.*` reference the fork does not have.
3. If upstream adds a new workflow, classify it the same way (lint/test keep,
   publish/infra drop) and extend the tables here.
4. Run `actionlint` before committing. It must print nothing and exit 0.
