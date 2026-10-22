# Fork CI Refactor Implementation Plan (rev 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep all 23 upstream workflows (22 under their names, `arc-smoke.yml` replaced) and make the fork's CI run end to end on free tiers: GitHub-hosted runners, BuildBuddy Cloud's free plan for Bazel remote execution and cache, GHCR for images and charts, a fork-owned signing keypair.

**Architecture:** Every upstream value becomes a repository variable or secret with a fork-safe default under one convention: `${{ vars.X || '<default>' }}` for values, job-level `if: ${{ vars.X_ENABLED == 'true' && ... }}` for gates. Bazel reaches BuildBuddy through a workflow-written `.bazelrc.remote` whose `build:remote_base` / `build:cache_only` lines override `.bazelrc` (it is try-imported last). Image repositories are derived in Bazel from stamped workspace status, so one variable moves every image. Signing uses `COSIGN_PRIVATE_KEY` unless OpenBao is explicitly enabled. Each task ends with a check that can fail; account-dependent facts are probed in Task 2 before anything builds on them.

**Tech Stack:** GitHub Actions YAML, actionlint 1.7.12 + shellcheck, yq, bash, gh, Bazel 9.2.0 via bazelisk, rules_oci 2.3.0, cosign, oras, BuildBuddy Cloud.

**Spec:** `docs/superpowers/specs/2026-10-21-fork-ci-refactor.md`

## Global Constraints

- Branch `fork-ci-refactor` cut from `origin/staging` with `--no-track`. Push only with `git push origin fork-ci-refactor:refs/heads/fork-ci-refactor`. Never push `staging`.
- Keep every upstream workflow file name except `arc-smoke.yml`, which becomes `bazel-remote-smoke.yml`. Also delete `.github/FUNDING.yml` and `.github/actionlint.yaml`.
- No rebrand: Go module paths, `@carverauto/serviceradar-cli`, `palisade`, image names, `docs/docusaurus.config.ts`, `.github/.testcoverage.yml` stay.
- Variable and secret names are exactly the spec's "Fork contract" table.
- `runs-on` values are only `ubuntu-24.04`, `macos-15`, `windows-latest`.
- BuildBuddy endpoints are `vars.BUILDBUDDY_ENDPOINT` (default `remote.buildbuddy.io`) and `vars.BUILDBUDDY_APP_URL` (default `https://app.buildbuddy.io`). Never `carverauto.buildbuddy.io` or `cache-proxy.carverauto.dev`.
- No secret value is ever echoed, and no `OCI_TOKEN`/`COSIGN_*`/`BUILDBUDDY_API_KEY` reaches a Bazel command line; the API key goes only into the gitignored `.bazelrc.remote` with `umask 077`.
- Docs under `docs/` and `BUILD.md` are ASCII only.
- Commit identity `156276185+jrmatherly@users.noreply.github.com`; commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Pinned action SHAs: `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`, `actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`, `docker/login-action@dbcb813823bdd20940b903addbd779551569679f` (v4.6.0), `docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069` (v4.4.1), `docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc` (v7.4.0).

## Review Focus

1. A `v*` tag pushed with no variables set must create nothing: `release.yml` `source` and `macos` skipped, `source-security` must not wait for a release. Pinned by Task 9 step 4.
2. `BAZEL_REMOTE_ENABLED=true` with `BUILDBUDDY_API_KEY` unset must fail before any Bazel invocation, naming the secret. Pinned by Task 6 step 3.
3. With `OPENBAO_SIGNING_ENABLED` unset and `COSIGN_PRIVATE_KEY` set, `cosign_init_sign_args` must select `--key env://COSIGN_PRIVATE_KEY`, never `hashivault://`. Pinned by Task 7 step 5.
4. `OCI_USERNAME` set and `OCI_TOKEN` unset (or the reverse) must fail at login naming both, not fall through to `GITHUB_TOKEN` under the wrong user. Pinned by Task 5 step 5.
5. The published image repository for every image must be `${OCI_REGISTRY}/${OCI_PROJECT}/<upstream name>` with no `registry.carverauto.dev` anywhere in `bazel query --output=build //docker/images:all` once stamped. Pinned by Task 5 step 3.

---

### Task 1: Branch, check script, close PR #1

**Files:**
- Create: `scripts/ci/check-fork-ci.sh`

**Interfaces:**
- Produces: `scripts/ci/check-fork-ci.sh` (no args; exit 0 = clean; prints `file:line: text` for every hit). It runs `actionlint -no-color` (shellcheck integration on) from the repo root, then greps the paths `.github buildbuddy.yaml .bazelrc build/rbe/BUILD build/ci/*.py docker/Dockerfile.rbe` for the extended regex `registry\.carverauto\.dev|carverauto\.buildbuddy\.io|cache-proxy\.carverauto\.dev|serviceradar-signing|arc-runner-set|HARBOR_|OPENBAO_ADDR: https://openbao|hashivault://cosign-release|github-signing-runner|svc\.cluster\.local|mfreeman` on lines whose first non-blank character is not `#`. Exit 1 on any hit or actionlint failure.

- [ ] **Step 1: Cut the branch**

```bash
git fetch origin staging
git checkout --no-track -b fork-ci-refactor origin/staging
```

- [ ] **Step 2: Write `scripts/ci/check-fork-ci.sh`** as specified; `set -euo pipefail`; `chmod +x`.

- [ ] **Step 3: Run it; it must fail on the untouched tree**

Run: `scripts/ci/check-fork-ci.sh; echo "exit=$?"`
Expected: output includes `.github/workflows/golangci-lint.yml:33:    runs-on: arc-runner-set`, `.bazelrc:105:build:remote_base --remote_executor=grpcs://carverauto.buildbuddy.io`, `build/ci/large_ingestion_gate.py:26:BUILDBUDDY_HOST = "carverauto.buildbuddy.io"`, shellcheck findings at `release.yml:503`, and `exit=1`.

- [ ] **Step 4: Close PR #1**

```bash
gh pr close 1 --repo jrmatherly/serviceradar --comment "Superseded by fork-ci-refactor (keep-and-refactor plan, rev 2)." --delete-branch
```

- [ ] **Step 5: Commit** `ci: add fork-ci check script`.

---

### Task 2: BuildBuddy account probe (owner-dependent)

**Files:**
- Create: `.github/workflows/bazel-remote-smoke.yml`
- Delete: `.github/workflows/arc-smoke.yml`

**Interfaces:**
- Consumes: owner has set repo secret `BUILDBUDDY_API_KEY` and, optionally, vars `BUILDBUDDY_ENDPOINT`, `BUILDBUDDY_APP_URL`.
- Produces: a composite-free, copy-pasteable step body used verbatim by Task 6 in every Bazel job, named `Configure Bazel remote execution`:
  ```yaml
  - name: Configure Bazel remote execution
    env:
      BAZEL_REMOTE_ENABLED: ${{ vars.BAZEL_REMOTE_ENABLED || 'true' }}
      BUILDBUDDY_ENDPOINT: ${{ vars.BUILDBUDDY_ENDPOINT || 'remote.buildbuddy.io' }}
      BUILDBUDDY_APP_URL: ${{ vars.BUILDBUDDY_APP_URL || 'https://app.buildbuddy.io' }}
      BUILDBUDDY_ORG_API_KEY: ${{ secrets.BUILDBUDDY_API_KEY }}
    run: scripts/ci/configure-bazel-remote.sh
  ```
  and `scripts/ci/configure-bazel-remote.sh` (created here): when `BAZEL_REMOTE_ENABLED != true` print `Bazel remote execution disabled.` and `exit 0` after writing an empty `.bazelrc.remote`; else fail (`exit 1`, message names `BUILDBUDDY_API_KEY`) if the key is empty; else `umask 077` and write `.bazelrc.remote`:
  ```
  common --remote_header=x-buildbuddy-api-key=<key>
  build:cache_only --remote_bytestream_uri_prefix=<endpoint>
  build:cache_only --remote_cache=grpcs://<endpoint>
  build:cache_only --bes_backend=grpcs://<endpoint>
  build:cache_only --bes_results_url=<app_url>/invocation/
  build:remote_base --remote_executor=grpcs://<endpoint>
  ```
  and append `echo "BUILDBUDDY_INVOCATIONS=<app_url>/invocation/" >> "$GITHUB_ENV"`. The `build:cache_only`/`build:remote_base` prefixes are required: plain `build` lines would lose to the `--config=remote` expansion on the command line (`.bazelrc` lines 246-248 say the same).

- [ ] **Step 1: Owner prerequisite (ask, do not guess)**

Confirm with the owner that `BUILDBUDDY_API_KEY` is set as a repository secret (an org API key from app.buildbuddy.io Settings -> API keys with executor permission) and ask which plan Settings -> Organization shows. Record the plan name in `docs/fork-ci.md` later.

- [ ] **Step 2: Write `scripts/ci/configure-bazel-remote.sh` and a unit check**

Run the script three ways from a scratch dir with `GITHUB_ENV=$(mktemp)`:
`BAZEL_REMOTE_ENABLED=false` → prints the disabled line, `.bazelrc.remote` exists and is empty, exit 0.
`BAZEL_REMOTE_ENABLED=true BUILDBUDDY_ENDPOINT=bb.example.com BUILDBUDDY_APP_URL=https://bb.example.com BUILDBUDDY_ORG_API_KEY=` → stderr contains `BUILDBUDDY_API_KEY`, exit 1, no file written.
Same with `BUILDBUDDY_ORG_API_KEY=k` → file has 6 lines, `grep -c bb.example.com` prints `5`, `stat -f %Lp .bazelrc.remote` prints `600`.

- [ ] **Step 3: Write `bazel-remote-smoke.yml`**

`workflow_dispatch` only; `permissions: contents: read`; one job on `ubuntu-24.04`: checkout, `scripts/install-bazelisk.sh` (after Task 4 fixes it; until then `command -v bazelisk`), the `Configure Bazel remote execution` step, then
```bash
bazel run -c opt --config=remote --lockfile_mode=error //build/ci:verify_git_metadata -- --expected-commit "$(git rev-parse HEAD)"
```
and a final step that appends the newest invocation URL to `$GITHUB_STEP_SUMMARY` (`bazel info` cannot give it; read `bazel-out/_tmp/actions` is not reliable either, so parse the `Streaming build results to:` line from the previous step's output captured to a file with `tee`). `git rm .github/workflows/arc-smoke.yml`.

- [ ] **Step 4: Push the branch and dispatch the smoke test**

```bash
git push origin fork-ci-refactor:refs/heads/fork-ci-refactor
gh workflow run bazel-remote-smoke.yml --repo jrmatherly/serviceradar --ref fork-ci-refactor
```
Expected: the run succeeds and the summary link opens an invocation on app.buildbuddy.io whose "Remote execution" panel shows actions executed remotely (not "cache only"). If the build fails with the executor image unavailable, that is Task 3's job: note it and proceed; if it fails on authentication or "no registered executors", stop and report to the owner, because the account does not have RBE and Decision 2 falls.

This run still uses upstream's executor image (`build/rbe/BUILD` is unchanged until Task 3) and so proves the account, not the image.

- [ ] **Step 5: Commit** `ci: add BuildBuddy remote-execution smoke test and configure-bazel-remote.sh; drop ARC smoke test`.

---

### Task 3: Fork-built RBE executor image

**Files:**
- Create: `.github/workflows/rbe-executor-image.yml`
- Modify: `build/rbe/BUILD:40` (`container-image`), `build/rbe/BUILD:39` (`dockerNetwork`)

**Interfaces:**
- Produces: image `ghcr.io/<owner>/serviceradar-rbe-executor:v1.0.25.1-fork.1` (tag = upstream's tag + `-fork.N`), public package. `build/rbe/BUILD` `exec_properties`: `"container-image": "docker://ghcr.io/jrmatherly/serviceradar-rbe-executor:v1.0.25.1-fork.1"`, and `"dockerNetwork": "host"` replaced by `"network": "off"` (`host` is not available on BuildBuddy Cloud).

- [ ] **Step 1: Write `rbe-executor-image.yml`**

`workflow_dispatch` with input `tag` (required, string); `permissions: contents: read, packages: write`; `ubuntu-24.04`; `timeout-minutes: 300`; steps: checkout, free disk (`sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android` as a single step), `docker/setup-buildx-action`, `docker/login-action` to `ghcr.io` with `github.actor`/`GITHUB_TOKEN`, `docker/build-push-action` with `context: .`, `file: docker/Dockerfile.rbe`, `platforms: linux/amd64`, `push: true`, `provenance: false`, `sbom: false`, `tags: ghcr.io/${{ github.repository_owner }}/serviceradar-rbe-executor:${{ inputs.tag }}`. Add `linux/arm64`? No: `build/rbe/BUILD` is amd64-only.

- [ ] **Step 2: Dispatch it and record the duration**

```bash
gh workflow run rbe-executor-image.yml --repo jrmatherly/serviceradar --ref fork-ci-refactor -f tag=v1.0.25.1-fork.1
```
Expected: success; note wall time in the commit message. `docker manifest inspect ghcr.io/jrmatherly/serviceradar-rbe-executor:v1.0.25.1-fork.1` succeeds anonymously (package is public: if it is private, make it public in the package settings; GHCR packages default to the repo's visibility only when linked, and this one is linked by the `org.opencontainers.image.source` label buildx adds).

- [ ] **Step 3: Point `build/rbe/BUILD` at it and drop host networking**

Then re-run `bazel-remote-smoke.yml`. Expected: success, and the invocation's action details show the fork's `container-image`. If an action fails for lack of network, the failing target needs network at build time; record which and set `"network": "bridge"` on the platform instead, in the same commit, with a comment naming the target.

- [ ] **Step 4: Check script**

Run: `scripts/ci/check-fork-ci.sh 2>&1 | grep -E 'build/rbe|Dockerfile.rbe'`
Expected: no output.

- [ ] **Step 5: Commit** `ci: build the RBE executor image on GitHub and publish it to GHCR; point the RBE platform at it`.

---

### Task 4: Hosted runners, shellcheck, bazelisk, protoc

**Files:**
- Modify: every workflow with `runs-on: arc-runner-set` (13 files after arc-smoke is gone) or `runs-on: serviceradar-signing` (5 files); `scripts/install-bazelisk.sh:34-39`; `tests-fingerprint-licensing.yml`; the 11 shellcheck sites actionlint reports (`native-addons.yml:77,226`, `wasm-plugins.yml:48`, `release.yml:503,615,690,738,906`)
- Delete: `.github/actionlint.yaml`, `.github/FUNDING.yml`

**Interfaces:**
- Produces: `scripts/install-bazelisk.sh` downloads the pinned release when a preinstalled `bazelisk` does not match the pinned sha256, instead of failing (upstream's own comment at `agent-platform-packages.yml:88-89` documents the current rejection).

- [ ] **Step 1: Runner labels and deletions**

```bash
sed -i '' -e 's/runs-on: arc-runner-set/runs-on: ubuntu-24.04/' -e 's/runs-on: serviceradar-signing/runs-on: ubuntu-24.04/' .github/workflows/*.yml
git rm .github/actionlint.yaml .github/FUNDING.yml
```
Reword the three runner comments: `helm-lint.yml:58` ("ARC runners have no docker.sock" → "Install a native helm binary rather than running helm through Docker."), `native-addon-version-bumps.yml:12` (`arc-runner-set has neither` → `a GitHub-hosted runner has neither`), `release.yml:388-391` (`serviceradar-signing does not mount /bazel-cache` → `Hosted runners have no /bazel-cache volume, so --config=ci is unusable here; --config=remote is the same remote_base graph with $HOME caches.`).

- [ ] **Step 2: Fix `scripts/install-bazelisk.sh`**

In the `command -v bazelisk` branch, verify the sha256 and on mismatch fall through to the download branch instead of exiting. Test locally: `PATH=/tmp/fakebin:$PATH` with a fake `bazelisk` file → script downloads and `bazelisk version` prints `1.28.1`.

- [ ] **Step 3: protoc for `tests-fingerprint-licensing.yml`**

PR #1's run failed with `Could not find protoc` from `rust/metric-proto`'s build script under `make lint-recog-additions`. Add a step before "Setup Rust": `sudo apt-get update && sudo apt-get install -y --no-install-recommends protobuf-compiler`.

- [ ] **Step 4: shellcheck**

For the five `SC2086` sites that deliberately word-split `${BAZEL_BUILD_FLAGS}`, add `# shellcheck disable=SC2086` on the line above each `bazel run ${BAZEL_BUILD_FLAGS}`. Fix `SC1083` at `native-addons.yml:77` and `wasm-plugins.yml:48` (literal `{`/`}` in a `${{ }}` inside a `run:` block: move the expression into a step `env:`), and `SC2155` at `native-addons.yml:226` (declare and assign separately).

- [ ] **Step 5: Verify**

Run: `grep -rn 'runs-on:' .github/workflows | grep -vE 'ubuntu-24.04|macos-15|windows-latest'; ls .github/workflows | wc -l; actionlint -no-color; echo "exit=$?"`
Expected: no grep output, `23` (22 upstream + bazel-remote-smoke + rbe-executor-image, minus arc-smoke = 23), no actionlint output, `exit=0`.
Run: `grep -lE '(secrets|vars)\.' .github/workflows/{elixir-dependency-audit,elixir-quality,golangci-lint,helm-lint,migration-collision-guard,native-addon-version-bumps,rust-checks,secret-scan,tests-fingerprint-licensing,web-ng-lint}.yml`
Expected: no output (source-security is excluded; Task 9 adds a `vars` gate to it).

- [ ] **Step 6: Commit** `ci: run every job on GitHub-hosted runners; fix bazelisk install, protoc, shellcheck findings`.

---

### Task 5: Registry contract: GHCR via stamped Bazel repositories

**Files:**
- Modify: `docker/images/image_inventory.bzl` (strip `registry.carverauto.dev/serviceradar/` from every `repository`, leaving the image name), `docker/images/push_targets.bzl` (derive repository via `expand_template` + `repository_file`), `scripts/workspace_status.sh` (emit `STABLE_OCI_REGISTRY`, `STABLE_OCI_PROJECT` from `OCI_REGISTRY`/`OCI_PROJECT` env with defaults `ghcr.io` / `jrmatherly`), `scripts/check-oci-image-tags-exist.sh`, `scripts/list-publishable-oci-repositories.sh`, `scripts/oci_registry.sh` (new `oci_registry_token <repo>` helper), the five token call sites (`sign-oci-publish.sh:128`, `verify-oci-publish.sh:234,307`, `sign-native-addon-publish.sh:107`, `sign-wasm-plugin-publish.sh:113`), `verify-oci-publish.sh:222-275` (referrers), the six workflow env blocks (`release.yml` 350-354 and 825-826, `publish-oci.yml` 44-47, `native-addons.yml` 34-37, `wasm-plugins.yml` 25-28, `external-wasm-plugin.yml` 225-228, `image-security.yml` 24-26) and the six login steps (`release.yml:669`, `publish-oci.yml:197`, `native-addons.yml:187`, `wasm-plugins.yml:148`, `image-security.yml:64`, `external-wasm-plugin.yml:310`), `docs/GHCR_PUBLISHING.md`

**Interfaces:**
- Produces, in every publish job env:
  ```yaml
  OCI_REGISTRY: ${{ vars.OCI_REGISTRY || 'ghcr.io' }}
  OCI_PROJECT: ${{ vars.OCI_PROJECT || github.repository_owner }}
  OCI_USERNAME: ${{ secrets.OCI_USERNAME || github.actor }}
  OCI_TOKEN: ${{ secrets.OCI_TOKEN || secrets.GITHUB_TOKEN }}
  OCI_USERNAME_SET: ${{ secrets.OCI_USERNAME != '' }}
  OCI_TOKEN_SET: ${{ secrets.OCI_TOKEN != '' }}
  ```
  plus `packages: write` in the job's `permissions` (`image-security`: `packages: read`). When creating a job-level `permissions` block for `release.yml` `publish`, carry `contents: write`, `id-token: write`, `statuses: read` from the workflow block. `release.yml` adds `OCI_CHART_REPOSITORY: ${{ vars.OCI_CHART_REPOSITORY || format('{0}/charts', github.repository_owner) }}` and `CHART_OCI_USERNAME`/`CHART_OCI_TOKEN` from the same two secrets. Bazel publish steps pass `--action_env=OCI_REGISTRY --action_env=OCI_PROJECT` is NOT needed: workspace status reads the job env directly.
- Produces: `oci_registry_token <repo_path> [user pass]` in `scripts/oci_registry.sh`: performs an unauthenticated `GET https://${REGISTRY_HOST}/v2/`, parses the `WWW-Authenticate: Bearer realm=...,service=...` header, requests `realm?service=...&scope=repository:<repo>:pull` (basic auth when user/pass given) and prints `.token // .access_token`. Works for GHCR (`/token`) and Harbor (`/service/token`) without knowing either path.
- Produces: `check_signature_accessory` in `verify-oci-publish.sh` tries the referrers API, and when the response is HTTP 404 falls back to `cosign triangulate --type signature <ref>@<digest>` and a HEAD on that tag (the "legacy" path already below it). GHCR returns 404 for referrers (verified 2026-10-21).

- [ ] **Step 1: Bazel repository derivation**

In `push_targets.bzl`, replace `repository = repository` on both `oci_push` calls with `repository_file = ":{}_repository".format(image)`, produced by `expand_template(name = "{}_repository", template = ["{{STABLE_OCI_REGISTRY}}/{{STABLE_OCI_PROJECT}}/" + name], substitutions = {"{{STABLE_OCI_REGISTRY}}": "ghcr.io", "{{STABLE_OCI_PROJECT}}": "jrmatherly"}, stamp = 1, stamp_substitutions = {...same keys to themselves...}, out = ...)`. `name` is the stripped inventory value. Update `command(description=...)` to use `name`. Read `rules_oci` 2.3.0 `oci/private/push.bzl:149-160` for the attribute contract (verified present).

- [ ] **Step 2: Workspace status**

Add to `scripts/workspace_status.sh`: `echo "STABLE_OCI_REGISTRY ${OCI_REGISTRY:-ghcr.io}"` and `echo "STABLE_OCI_PROJECT ${OCI_PROJECT:-jrmatherly}"`.

- [ ] **Step 3: Verify the derivation (Review Focus 5)**

Run (needs a Bazel-capable machine or the smoke workflow with an extra step): `OCI_REGISTRY=example.test OCI_PROJECT=acme bazel build --stamp //docker/images:core_elx_image_amd64_repository && cat bazel-bin/docker/images/core_elx_image_amd64_repository.txt`
Expected: `example.test/acme/serviceradar-core-elx`. And `grep -rn 'registry.carverauto.dev' docker/images/` prints nothing.

- [ ] **Step 4: Scripts**

`check-oci-image-tags-exist.sh` and `list-publishable-oci-repositories.sh` currently parse `"repository"` strings from the inventory; change them to prefix the stripped name with `${OCI_REGISTRY}/${OCI_PROJECT}/`. Replace the five Harbor token URLs with `oci_registry_token`. Implement the referrers fallback. Drop the `HARBOR_*` branches of `resolve_registry_auth` (lines 102-109).

- [ ] **Step 5: Workflows: env, permissions, login guard (Review Focus 4)**

Apply the env block to all six jobs. In each of the six login steps replace the dead `-z OCI_USERNAME || -z OCI_TOKEN` check with: `if [[ "${OCI_USERNAME_SET}" != "${OCI_TOKEN_SET}" ]]; then echo "Set both OCI_USERNAME and OCI_TOKEN secrets or neither." >&2; exit 1; fi`, and reword the five Harbor messages and the `release.yml:355-364` / `publish-oci.yml:48-57` comments to say "the registry in OCI_REGISTRY".

- [ ] **Step 6: Verify**

Run: `grep -rn 'HARBOR' .github/workflows scripts/*.sh | grep -v '^\S*:[0-9]*:\s*#'; grep -rn 'service/token' scripts; actionlint -no-color; echo "exit=$?"`
Expected: no grep output; `exit=0`.
Run the token helper against GHCR: `REGISTRY_HOST=ghcr.io bash -c 'source scripts/oci_registry.sh; oci_registry_token sigstore/cosign/cosign | cut -c1-8'`
Expected: eight characters of a token, exit 0.

- [ ] **Step 7: Rewrite `docs/GHCR_PUBLISHING.md`** so the title is true: GHCR by default, `OCI_REGISTRY`/`OCI_PROJECT` env, `GITHUB_TOKEN` auth, no Harbor robot section, `make push_all` example with `OCI_USERNAME`/`OCI_TOKEN`, verification with the fork's `docs/cosign.pub` (Task 7), and a note that GHCR has no referrers API so signatures live on the `.sig` tag.

- [ ] **Step 8: Commit** `ci: publish images, charts and add-ons to vars.OCI_REGISTRY (GHCR by default) with a registry-neutral token helper`.

---

### Task 6: Bazel remote execution on BuildBuddy

**Files:**
- Modify: the nine `.bazelrc.remote` writer steps (`release.yml` three jobs: 154-173, 249-265, 462; `agent-platform-packages.yml` 65-92, 229-236; `publish-oci.yml` ~140; `native-addons.yml` 136-146 and 412-419; `wasm-plugins.yml` 94-116), all 32 `--config=remote`/`--config=cache_only` sites, `build/ci/large_ingestion_gate.py:26,28`, `build/ci/wait_for_large_ingestion_gate.py:77`, the two "Wait for large-ingestion gate" steps (`release.yml` 165-173, 500-512)

**Interfaces:**
- Consumes: the `Configure Bazel remote execution` step and script from Task 2.
- Produces: every Bazel job has, in `env`, `BAZEL_REMOTE_CONFIG: ${{ (vars.BAZEL_REMOTE_ENABLED || 'true') == 'true' && '--config=remote' || '' }}` for Linux jobs and `BAZEL_CACHE_CONFIG: ${{ (vars.BAZEL_REMOTE_ENABLED || 'true') == 'true' && '--config=cache_only' || '' }}` for the macOS jobs. `BAZEL_BUILD_FLAGS` (release, publish-oci, native-addons job-level and `native-addons.yml:261` step-level) becomes `-c opt ${{ ...same expression... }} --remote_download_outputs=all --lockfile_mode=error`. Inline `--config=remote` → `${BAZEL_REMOTE_CONFIG}`; inline `--config=darwin_local --config=cache_only` → `--config=darwin_local ${BAZEL_CACHE_CONFIG}` (macOS must never get `remote_base`: it sets a Linux RBE platform). wasm-plugins' extra lines (`--lockfile_mode=error`, `--remote_timeout=10m`, `--remote_download_minimal`, `--remote_upload_local_results`, `--jobs=100`, `--strategy=ExpandTemplate=local`, `--strategy=NpmPackageExtract=local`, `--strategy=CopyDirectory=local`) are appended to `.bazelrc.remote` by that workflow after the shared script runs, with the `build:remote_base` prefix.
- Produces: `large_ingestion_gate.py` reads `BUILDBUDDY_HOST` and `TARGET_URL_PREFIX` from env `BUILDBUDDY_APP_URL` (default `https://app.buildbuddy.io`), keeping the exact-match policy against that derived value; `wait_for_large_ingestion_gate.py` unchanged in logic. The two workflow steps get `if: ${{ vars.LARGE_INGESTION_GATE_ENABLED == 'true' }}` and pass `--target-url-prefix "${BUILDBUDDY_APP_URL}/invocation/"`.

- [ ] **Step 1: Replace the nine writer steps** with the Task 2 step. Delete the per-job `BUILDBUDDY_ORG_API_KEY: ${{ secrets.BUILDBUDDY_ORG_API_KEY || secrets.BUILDBUDDY_API_KEY }}` env lines (the step carries its own).

- [ ] **Step 2: Rewrite every `--config` site**

Run after editing: `grep -nE -- '--config=(remote|cache_only)' .github/workflows/*.yml | grep -vE 'BAZEL_(REMOTE|CACHE)_CONFIG|^\S+:[0-9]+:\s*#'`
Expected: no output.

- [ ] **Step 3: Verify the missing-key guard (Review Focus 2)** is the Task 2 step 2 negative case; re-run it after any script change.

- [ ] **Step 4: Ingestion gate**

Edit the two Python constants to derive from `os.environ.get("BUILDBUDDY_APP_URL", "https://app.buildbuddy.io")`; run `python3 -m pytest build/ci/ -q` or the Bazel test for `large_ingestion_gate` and fix any test that pinned the old host (search `build/ci/*_test.py` for `carverauto`). Add the `if:` and the new prefix to both workflow steps with the comment `# Requires the BazelCI LargeIngestionGate action to post its status; see docs/fork-ci.md.`

- [ ] **Step 5: Verify**

Run: `scripts/ci/check-fork-ci.sh; echo "exit=$?"`
Expected: remaining hits are only OpenBao/signing lines (Task 7) and `svc.cluster.local`/registry lines in `buildbuddy.yaml` (Task 8); nothing from `.bazelrc`-driven workflow lines, `build/ci`, `build/rbe`.

- [ ] **Step 6: Commit** `ci: route every Bazel job through BuildBuddy Cloud via .bazelrc.remote; gate the large-ingestion wait`.

---

### Task 7: Signing: fork-owned keys

**Files:**
- Modify: `release.yml` 734-737,802; `publish-oci.yml` 254-257,270; `native-addons.yml` 223-225,250; `wasm-plugins.yml` 23-37,158-161,182-195; `external-wasm-plugin.yml` 247-249,322-325,340; `docs/cosign.pub`; `elixir/web-ng/config/config.exs:271-276`; `helm/serviceradar/values.yaml:1403-1407`; `helm/serviceradar/values-demo.yaml:562-566`; `go/pkg/agent/release_signing_key.txt`; `helm/serviceradar/values*.yaml` `agentReleasePublicKey`; `docs/RELEASE_PUBLISHING.md` CI Prerequisites

**Interfaces:**
- Produces, in each signing job env: `OPENBAO_SIGNING_ENABLED: ${{ vars.OPENBAO_SIGNING_ENABLED == 'true' }}`, `COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}`, `COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}`, and the `OPENBAO_ADDR`/`OPENBAO_K8S_ROLE`/`COSIGN_KEY_REF` lines wrapped so they are set only when enabled: `COSIGN_KEY_REF: ${{ vars.OPENBAO_SIGNING_ENABLED == 'true' && 'hashivault://cosign-release' || '' }}`, same pattern for the two OpenBao vars with their upstream values (the values are then upstream's cluster addresses, kept only as the documented OpenBao defaults; move them to `scripts/ci/prepare-openbao-cosign-env.sh`'s existing `: "${OPENBAO_ADDR:=...}"` defaults and delete the workflow lines instead, which also satisfies the check script). Every `source ./scripts/ci/prepare-openbao-cosign-env.sh` becomes `if [[ "${OPENBAO_SIGNING_ENABLED}" == "true" ]]; then source ./scripts/ci/prepare-openbao-cosign-env.sh; fi`.
- Produces: `wasm-plugins.yml` job env gains `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY`, `PLUGIN_UPLOAD_SIGNING_KEY_ID`, `PLUGIN_UPLOAD_SIGNING_SIGNER` from secrets (as `external-wasm-plugin.yml:247-249` already does).
- Owner generates (commands to give them verbatim):
  ```bash
  cosign generate-key-pair            # cosign.key, cosign.pub, prompts for a password
  openssl genpkey -algorithm ed25519 -out agent-release.pem && openssl pkey -in agent-release.pem -pubout -out agent-release.pub
  ```
  Read `scripts/test-external-wasm-plugin-release-workflow.sh` for how a Wasm upload-signing test key is generated and give the owner the same command for the real one. Secrets go to the `release` environment: `COSIGN_PRIVATE_KEY` (contents of cosign.key), `COSIGN_PASSWORD`, `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` (format: whatever `//tools/go/derive_agent_release_public_key` reads; check its source first), `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY`, `_KEY_ID` (e.g. `jrmatherly-first-party-v1`), `_SIGNER` (e.g. `jrmatherly-release`). The owner sends only the PUBLIC halves to the repo.

- [ ] **Step 1: Owner prerequisite**: ask for the public halves (cosign.pub, agent-release.pub, and the derived agent public key string via `bazel run //tools/go/derive_agent_release_public_key` with the secret in env) and confirmation the secrets are set. Do not proceed to step 3 without them.

- [ ] **Step 2: Workflow edits** per Interfaces.

- [ ] **Step 3: Replace the committed public keys**

`docs/cosign.pub`, `config.exs`, both values files (cosign); `go/pkg/agent/release_signing_key.txt` and both `agentReleasePublicKey` values (agent). Run `bazel test //build/contracts:first_party_plugin_cosign_key_consistency_test` (or `python3 build/contracts/first_party_plugin_cosign_key_consistency_test.py`) and the equivalent agent-key consistency target found via `grep -rn release_signing_key build/contracts/BUILD.bazel`.
Expected: both pass.

- [ ] **Step 4: Verify** `grep -rn 'OPENBAO_ADDR\|hashivault' .github/workflows` prints nothing; `scripts/ci/check-fork-ci.sh` shows no signing hits.

- [ ] **Step 5: Verify key selection (Review Focus 3)**

Run: `env -i "$(command -v bash)" -c 'OPENBAO_SIGNING_ENABLED=false COSIGN_PRIVATE_KEY=x COSIGN_PASSWORD=y; source scripts/cosign_common.sh; cosign_init_sign_args; printf "%s\n" "${COSIGN_SIGN_ARGS[@]}"'`
Expected: contains `--key` and `env://COSIGN_PRIVATE_KEY`; no `hashivault`.

- [ ] **Step 6: Update `docs/RELEASE_PUBLISHING.md`** CI Prerequisites to the fork contract (GHCR via `GITHUB_TOKEN`, BuildBuddy API key, `COSIGN_PRIVATE_KEY`, agent key, Wasm key secrets), replace `carverauto/serviceradar` in the `gh` examples with `jrmatherly/serviceradar`, and drop the `serviceradar-signing` paragraph.

- [ ] **Step 7: Commit** `ci: sign with a fork-owned cosign key and agent release key; OpenBao behind OPENBAO_SIGNING_ENABLED`.

---

### Task 8: `buildbuddy.yaml` for hosted BuildBuddy workflows

**Files:**
- Modify: `buildbuddy.yaml` (every action)

**Interfaces:**
- Produces: `BazelCI` action: `self_hosted`, `pool`, `container_image: docker://...`, `platform_properties` removed; `container_image: "ubuntu-24.04"`; `env.OCI_REGISTRY: "ghcr.io"`, `OCI_AUTH_REQUIRED` removed (anonymous public pulls); `resource_requests` kept at `cpu: "7"`, `memory: "28GB"`, `disk: "40GB"` (hosted cap unknown; see step 3); the `//:buildbuddy_setup_docker_auth` step kept (it is best-effort without `OCI_AUTH_REQUIRED`). Every other action (`BazelCI Core Integration`, `BazelCI Web-NG DB`, `LargeIngestionGate`, `SchemaTemplateQualification`, `SrqlParity`, `GodViewAcceptance`, `WebNgDbDiagnostic`, `WorldWorkerScale`, the `IntegrationBenchmark*` set) has its `triggers:` block replaced by a comment `# Disabled on the fork: needs in-cluster fixtures (see docs/fork-ci.md). Dispatch manually from the BuildBuddy UI.` and keeps the rest of its definition. `*.svc.cluster.local` and `*.carverauto.dev` env values in those actions stay inside the disabled actions; the check script therefore excludes `buildbuddy.yaml` lines between `# Disabled on the fork` and the next `- name:`. Implement that exclusion in `scripts/ci/check-fork-ci.sh` with awk, and keep it simple.

- [ ] **Step 1: Owner prerequisite**: repo linked on app.buildbuddy.io Workflows page (Task 2 step 1 asked). If the page refused or the plan hides Workflows, skip this task, leave `buildbuddy.yaml` as is except deleting the `BazelCI` trigger too, and record "Workflows not available on this plan" in `docs/fork-ci.md`.

- [ ] **Step 2: Edit `buildbuddy.yaml`** per Interfaces; `yq '.actions[] | select(.triggers != null) | .name' buildbuddy.yaml` prints only `BazelCI`.

- [ ] **Step 3: Push and watch the PR status**

After Task 10 opens the PR, a `BazelCI` commit status should appear. Expected: it runs on a hosted runner and either passes, or fails for one of: resource request rejected (lower to the documented default `cpu: "3"`, `memory: "8GB"` and retry, then record the cap), a tool missing from the Ubuntu image (add an `apt-get` to the action's first step), or a test needing a database (that test is tagged wrong: report it, do not loosen). Record the outcome in `docs/fork-ci.md`.

- [ ] **Step 4: Commit** `ci: run the BazelCI unit sweep on BuildBuddy-hosted workflow runners; disable fixture-bound actions`.

---

### Task 9: Publish gates and remaining upstream references

**Files:**
- Modify: `release.yml` (`source`, `macos`, `finalize` "Advance demo release source branch" step), `native-addons.yml`, `wasm-plugins.yml`, `cli-npm-publish.yml`, `palisade-publish.yml`, `docs-pages.yml`, `agent-platform-packages.yml`, `source-security.yml:78,108`, `external-wasm-plugin.yml:7,48`, `cli-npm-publish.yml:16-19`

**Interfaces:**
- `release.yml` `source`: `if: ${{ vars.PUBLISH_ENABLED == 'true' }}`. `macos` (has no `if` or `needs` today): `if: ${{ vars.PUBLISH_ENABLED == 'true' && vars.MACOS_SIGNING_ENABLED == 'true' }}`. "Advance demo release source branch": add `&& vars.DEMO_RELEASE_BRANCH_ENABLED == 'true'` (add this var to the spec table as default unset).
- `native-addons.yml` `publish`: prepend `vars.PUBLISH_ENABLED == 'true' &&` to its existing tag condition. `wasm-plugins.yml` `publish`, `palisade-publish.yml` `publish`: `if: ${{ vars.PUBLISH_ENABLED == 'true' }}`. `cli-npm-publish.yml` `publish`: `if: ${{ vars.PUBLISH_ENABLED == 'true' || (github.event_name == 'workflow_dispatch' && inputs.dry_run) }}`.
- `docs-pages.yml`: `build` ungated (free typecheck); the `configure-pages`/`upload-pages-artifact` steps in `build` and the whole `deploy` job get `if: ${{ vars.DOCS_PAGES_ENABLED == 'true' }}`.
- `agent-platform-packages.yml`: `macos-arm64` (unsigned) stays ungated; `macos-signing-rehearsal` gets `&& vars.MACOS_SIGNING_ENABLED == 'true'`.
- `source-security.yml`: both release steps get `&& vars.PUBLISH_ENABLED == 'true'` so a tag with publishing off does not poll for an hour.
- `external-wasm-plugin.yml`: `PLUGIN_ORG: ${{ vars.PLUGIN_ORG || github.repository_owner }}` in the build job env, guard `[[ "${PLUGIN_ORG}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "PLUGIN_ORG must be a GitHub owner name" >&2; exit 1; }` then the regex `^${PLUGIN_ORG}/serviceradar-plugin-[a-z0-9]+([a-z0-9-]*[a-z0-9])?$`; input description `External plugin repository under PLUGIN_ORG (default: this repository's owner).`
- `cli-npm-publish.yml:16-19`: comment says the trusted publisher points at this repository, not `carverauto/serviceradar`.

- [ ] **Step 1: Apply.** Job-level `if` can read `vars`, not `secrets`.

- [ ] **Step 2: Verify with yq**: `source.if` in release, `publish.if` in the four tag publishers, `deploy.if` in docs-pages, `macos.if` in release contain the expected variables.

- [ ] **Step 3: Check script clean**: `scripts/ci/check-fork-ci.sh; echo "exit=$?"` → no output, `exit=0`. And `grep -rn 'carverauto' .github | grep -v '^\S*:[0-9]*:\s*#'` prints only `GOPRIVATE`/`GONOSUMDB` module globs, `@carverauto/serviceradar-cli`, and `.testcoverage.yml` `local-prefix`.

- [ ] **Step 4: Tag test (Review Focus 1)**, after the PR is open: push `v0.0.0-forkci-test` to the branch, then `gh run list --event push --limit 10 --json name,databaseId` and for each of release / native-addons / wasm-plugins `gh run view <id> --json jobs -q '.jobs[] | .name + " " + .conclusion'`: every job `skipped`; `gh release list` shows no such tag; `source-security` completes within 5 minutes. Delete the tag.

- [ ] **Step 5: Commit** `ci: gate tag-triggered publishing, Pages, macOS signing and the demo branch behind repository variables`.

---

### Task 10: Docs, PR, verification

**Files:**
- Create: `docs/fork-ci.md`
- Modify: `AGENTS.md` (one bullet after the GitHub-host rule), `BUILD.md` (Bazel `9.2.0`, bazelisk `1.28.1`, clone URL `jrmatherly/serviceradar`), `docs/SBOM.md` (GHCR not Harbor; registry path `ghcr.io/<owner>/<image>:<tag>`), `docs/docs/release-artifact-integrity.md:73-89` (secrets renamed to `OCI_USERNAME`/`OCI_TOKEN`, Harbor wording removed)

**Interfaces:**
- `docs/fork-ci.md` sections: Services and free tiers (the spec table, verbatim, plus the BuildBuddy plan name and the Task 8 outcome); Fork contract (spec table); Owner actions; Per-workflow table (24 rows: 22 upstream + 2 new, each with trigger, purpose, contract entries used, `kept` / `kept, gated` / `new` / `replaced arc-smoke`); `buildbuddy.yaml` actions (enabled / disabled and why); Porting upstream workflow changes (apply the diff by hand, re-apply the contract, run `scripts/ci/check-fork-ci.sh`; never add `arc-runner-set`, `serviceradar-signing`, `HARBOR_*`, `self_hosted`, or a carverauto hostname); Known blockers (npm and hex package names, macOS notarization, in-cluster fixture actions, `MODULE.bazel` base-image mirrors).

- [ ] **Step 1: Write the docs**; `LC_ALL=C grep -n '[^[:print:][:space:]]' docs/fork-ci.md BUILD.md docs/SBOM.md docs/GHCR_PUBLISHING.md docs/RELEASE_PUBLISHING.md` prints nothing.

- [ ] **Step 2: Commit, push, open the PR**

```bash
git push origin fork-ci-refactor:refs/heads/fork-ci-refactor
gh pr create --repo jrmatherly/serviceradar --base staging --head fork-ci-refactor --title "ci: run upstream's workflows on the fork with free-tier services" --body-file <body>
```
Body: spec Decisions + Services table + a test plan listing the 9 PR-triggered lint workflows, the smoke run, the tag test, and the dry runs below.

- [ ] **Step 3: Read the checks**

`gh pr checks <n> --watch`. Expected green: `lint`, `Elixir Quality`, `Elixir Dependency Audit`, `Helm Lint`, `Web-NG Assets`, `Secret Scan`, `Migration collision guard`, `Fingerprint Licensing`, `Native add-on version bumps`, plus `BazelCI` from BuildBuddy if Task 8 ran. `rust-check` and `Source Security Scan` do not trigger on this PR (paths / no `pull_request`): dispatch `source-security.yml` on the branch and confirm it uploads nothing and passes. A red check is fixed in the workflow's install steps, never by loosening the check.

- [ ] **Step 4: Publish dry runs (needs Task 7 secrets)**

`gh workflow run publish-oci.yml --ref fork-ci-refactor -f publish_scope=web-stack-commit-only -f expected_commit=<sha>` → images `ghcr.io/jrmatherly/serviceradar-core-elx:sha-<sha>` and `serviceradar-web-ng:sha-<sha>` exist (`oras manifest fetch --descriptor`), `cosign verify --key docs/cosign.pub` passes on both. Then `gh workflow run release.yml --ref fork-ci-refactor -f tag=v0.0.0-forkci-test -f dry_run=true` after re-pushing the test tag, with `PUBLISH_ENABLED=true` set temporarily; expected: `publish` reaches and completes the `//:images` Bazel build on BuildBuddy; note the cache transfer shown in the BuildBuddy invocation against the 100 GB/month allowance. Unset `PUBLISH_ENABLED` and delete the tag afterwards.

- [ ] **Step 5: Final commit** `docs: fork CI contract, services, porting rules` and the Task 9 step 4 / Task 8 step 3 outcomes written into `docs/fork-ci.md`.

---

## Self-review notes

- Spec coverage: Decisions 1-8 map to Tasks 5, 6, 3, 7, 7, 4+2, 8, 1. Every contract row is set in Task 5 (OCI), 6 (Bazel), 7 (signing), 9 (gates, PLUGIN_ORG, DEMO_RELEASE_BRANCH_ENABLED), 3 (RBE_EXECUTOR_IMAGE). Acceptance bullets map to Task 1 (script), 4 step 5 (file count), 10 step 3 (green), 2 step 4 and 3 step 3 (smoke + image), 10 step 4 (dry runs), 10 step 1 and 5 step 7 and 7 step 6 (docs).
- Names: `BUILDBUDDY_ORG_API_KEY` remains the env name scripts read; its only source is `secrets.BUILDBUDDY_API_KEY`. `OCI_USERNAME`/`OCI_TOKEN` are both env and secret names on purpose. `BAZEL_REMOTE_CONFIG` vs `BAZEL_CACHE_CONFIG` is deliberate: macOS never gets `remote_base`.
- Owner-blocked points are Task 2 step 1, Task 7 step 1, Task 8 step 1. Everything else runs without the owner. Tasks 4, 5, 9 do not depend on the probe and can proceed while waiting.
- Unverified until executed: BuildBuddy free-plan Workflows availability and `resource_requests` cap (Task 8), cache-transfer consumption per release (Task 10 step 4), `Dockerfile.rbe` build time on a hosted runner (Task 3 step 2), whether any Bazel action needs network (Task 3 step 3).
