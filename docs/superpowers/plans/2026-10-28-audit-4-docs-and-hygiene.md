# Docs and hygiene implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the fork's documents and agent instructions from sending a reader to upstream's registry, forge or cluster, and put a gate behind the local checks that fail with nobody watching, including the fork's own CI acceptance script, which nothing runs today.

**Architecture:** Docs tasks rewrite or mark upstream-only text so every instruction a reader can follow works on this fork. Gate tasks add the missing check to an existing lint path (`make lint-go`, the `lint` workflow) and fix what it flags in the same PR, so the gate is proven to fail before it is proven to pass. One PR per task.

**Tech Stack:** Markdown, golangci-lint 2.11.4 (pinned in `Makefile:28-30`), shellcheck 0.11, Bazel `MODULE.bazel` and its lock, mise.

**Spec:** Tiers 4 and 5 of `private/findings/2026-10-28-project-audit.md` (gitignored). The Dockerfile build-path retirement is a separate proposed session and owns `docker/LOCAL_BUILD.md`, `scripts/build-images.sh`, `scripts/docker-login.sh` and `docker/images/Dockerfile.workflow-runner:21,90`; this plan does not touch them. The upstream review backlog is a run of the `upstream-review` skill, not a task here. The Helm chart's image registry default (`helm/serviceradar/values.yaml:56,59`) and `scripts/get-latest-version.sh:41,68` are rebrand scope and stay as they are; `docs/fork-ci.md:59-61` records that the chart keeps upstream's registry.

## Global constraints

- Markdown under `docs/` is ASCII only (`AGENTS.md`). No long dashes anywhere.
- Historical records keep upstream references under the Forgejo-link rule: `CHANGELOG`, `openspec/changes/archive/`, `docs/learnings/adlr/`, and fixtures that exercise the Forgejo release path (`AGENTS.md:96`).
- Forgejo issue numbers do not map to GitHub numbers; drop a link rather than swap the host.
- The fork's chart will live at `oci://ghcr.io/jrmatherly/charts/serviceradar` (`docs/fork-ci.md:79`) but is not published yet: `crane ls` and `helm show chart` return denied, and there is no `v*` tag or GitHub release. Images are at `ghcr.io/jrmatherly/serviceradar-*` under `latest` and `sha-<commit>` only; the cosign key is `docs/cosign.pub`.
- `.github/` and `build/ci/*.py` changes run `scripts/ci/check-fork-ci.sh` (`docs/fork-ci.md:4-5`).
- `docs/node_modules` is absent on a fresh checkout; docs builds start with `sfw npm ci`.
- pytest is not installed; run `build/ci` tests with `python3 -B -m unittest <file>` or their Bazel targets.
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit.

## Review focus

- A reader of `README.md` or `INSTALL.md` who runs the Helm line and gets a pull error; Task 2 installs from the checkout until the chart is published.
- An agent that reads `AGENTS.md:83-90` and files a PR against upstream (Task 1).
- A gofmt formatter block whose `fmt` write path ignores the linter exclusions; Task 6 copies the paths into `formatters.exclusions`.
- An OTP bump that leaves `MODULE.bazel.lock` on 28.1, which fails every `--lockfile_mode=error` release job; Task 8 regenerates the lock.
- A worktree removal that silently deletes ignored local state; Task 9 looks at ignored files first.

## Dependency graph

All tasks are independent and branch from `staging`. Tasks 1 to 4 and 10 are docs. Tasks 5 to 8 are gates and pins; Task 7 wires `check-fork-ci.sh` into CI, so land it before any other task that relies on that script running in CI. Task 9 is local-only and produces no PR.

---

### Task 1: Point the collaboration-host rule at this fork

**Files:**
- Modify: `AGENTS.md:83-90` (the hard rule), `:246` (names Go services "core, sync, registry" and a "Next.js web UI"; `go/cmd` has none of those three and web-ng is Phoenix), `:251` (lists `go/pkg` packages "identity map, registry, sync integrations" that `ls go/pkg` does not show), `:313` (refers to a `.bazelrc.remote` hard rule that does not exist in the file)

- [ ] **Step 1: Rewrite the hard rule**

Replace "for `carverauto/serviceradar` go through `gh` against <https://github.com/carverauto/serviceradar>" with "for this repository go through `gh` against its `origin` (`jrmatherly/serviceradar`); upstream is `carverauto/serviceradar` and receives nothing unless the owner says so". Keep the two Forgejo sub-bullets. Optional guard the owner can apply: `git remote set-url --push upstream DISABLED` and the same for `carverauto` (both remotes have push URLs today).

- [ ] **Step 2: Fix the three overview lines from the tree**

Line 246: list the Go binaries from `ls go/cmd` and say "Phoenix (web-ng) UI". Line 251: list from `ls go/pkg`. Line 313: either drop the clause or add the rule it refers to (copy `.bazelrc.remote` from the main checkout into each worktree before any `--config=remote` build).

- [ ] **Step 3: Prove it**

Run: `grep -n 'carverauto/serviceradar' AGENTS.md`
Expected: the rewritten rule's one "upstream is `carverauto/serviceradar`" clause and line 142 (the upstream issue 5745 approval link), nothing else.

- [ ] **Step 4: Commit** as `docs(agents): name the fork as the collaboration host`.

---

### Task 2: Install and verify from the fork in the README and INSTALL guides

**Files:**
- Modify: `README.md:101` (clone URL), `:116-130` (Helm), `:162-198` (cosign), `:202` (upstream release example `APP_TAG=v1.4.49`), `:206-225` (chart URL, pull secret, ArgoCD repo URL)
- Modify: `INSTALL.md:22,40,49,61` (the same Helm and cosign lines)

- [ ] **Step 1: Rewrite with the fork's values**

Clone `https://github.com/jrmatherly/serviceradar.git` (as `BUILD.md:48` already does). Helm installs from the checkout until the chart is published: `helm upgrade --install serviceradar ./helm/serviceradar --set image.registry=ghcr.io/jrmatherly --set image.registryPullSecret=""` with one line saying the OCI chart at `oci://ghcr.io/jrmatherly/charts/serviceradar` publishes on the fork's first release (switch the commands in that release PR). Keep one line on `image.registryPullSecret`, since `values.yaml:59` still defaults to upstream's secret name. Cosign: `cosign verify --key docs/cosign.pub ghcr.io/jrmatherly/serviceradar-core-elx:sha-<commit>` (no `v*` tags exist); drop the keyless-identity variant at 190-198 (the fork signs with `COSIGN_PRIVATE_KEY`). Replace the `v1.4.49` example with `sha-<commit>`.

- [ ] **Step 2: Run the verify line and a template render**

Run: `cosign verify --key docs/cosign.pub ghcr.io/jrmatherly/serviceradar-core-elx:latest >/dev/null && echo VERIFIED` and `helm template serviceradar ./helm/serviceradar --set image.registry=ghcr.io/jrmatherly --set image.registryPullSecret="" | grep -c 'ghcr.io/jrmatherly'`
Expected: `VERIFIED`; a count above 0 and no `registry.carverauto.dev` in the render (`| grep -c registry.carverauto.dev` prints 0).

- [ ] **Step 3: Prove it**

Run: `grep -n 'registry.carverauto.dev\|carverauto/serviceradar.git\|Harbor\|v1\.4\.49' README.md INSTALL.md`
Expected: no output.

- [ ] **Step 4: Commit** as `docs(readme): install and verify against the fork's registry`.

---

### Task 3: Retire the Harbor and Forgejo release docs

**Files:**
- Delete: `RELEASE.md` (158 lines, Harbor and Forgejo throughout; `docs/RELEASE_PUBLISHING.md` is the fork's current doc)
- Modify: `GOVERNANCE.md:47` and `docs/LF/LF_Github_Recommendations.md:36` (links to it). `build/ci/detect_docs_only_test.py:39` stays: it tests the root `*.md` pattern, not the file.
- Modify: `docker/README.md:63-69`, `openspec/AGENTS.md:404,434-464`, `docs/RELEASE_PUBLISHING.md:27-29`
- Modify: `docs/checker-template-registration.md:152,178`, `go/pkg/edgeonboarding/README.md:65`, `docs/sigstore/README.md:104` (registry examples)

- [ ] **Step 1: Confirm `RELEASE.md` has nothing `docs/RELEASE_PUBLISHING.md` lacks**

Read both. Move any surviving fact into the newer doc, delete the old one, repoint the two links.

- [ ] **Step 2: Fix the other docs**

`docker/README.md`: cnpg, core-elx and web-ng are amd64-only, the other images are multi-arch (`docker-compose.arm64.yml:5`; `crane manifest ghcr.io/jrmatherly/serviceradar-cert-generator:latest` is an index); examples use `ghcr.io/jrmatherly/...`; published by `publish-oci.yml` and `release.yml`. `openspec/AGENTS.md`: `cut-release.sh --push` pushes the branch and creates no tag (`cut-release.sh:39-41,205-214`), the owner tags the staging merge commit and that triggers `release.yml`; remove the "Create tag" lines near 437 and 450; chart URL is the fork's. `RELEASE_PUBLISHING.md:27-29`: the demo-branch advance runs only when `DEMO_RELEASE_BRANCH_ENABLED` is `true` (`release.yml:1242-1244`; off on this fork). The three registry examples use `ghcr.io/jrmatherly/...`.

- [ ] **Step 3: Prove it**

Run: `python3 -B -m unittest build/ci/detect_docs_only_test.py` and `git grep -n 'registry.carverauto.dev\|code.carverauto.dev' -- RELEASE.md docker/README.md openspec/AGENTS.md docs/RELEASE_PUBLISHING.md docs/checker-template-registration.md go/pkg/edgeonboarding/README.md docs/sigstore/README.md`
Expected: `Ran 16 tests ... OK`; grep prints nothing.

- [ ] **Step 4: Commit** as `docs(release): drop the harbor and forgejo release guide`.

---

### Task 4: Mark upstream-only runbooks and fix the broken link

**Files:**
- Modify: `docs/agent-runbooks.md`, moving by heading, not by line: "Demo Namespace Helm Refresh" with its fast path (23-70), "Release Playbook" (539-559), "CNPG Database Access (Kubernetes demo-staging)" with its Notes block (560-647), "Hosted-Bazel dispatches (workflow fleet)" (818-855), and "SRQL Fixture Integration Tests" (718, in-cluster BuildBuddy only, a known blocker in `docs/fork-ci.md`); the link at `:757`; the registry example at `:400` in "Docker Compose mTLS ERTS", which does not move
- Modify: `AGENTS.md:304-307` (the runbook list)

- [ ] **Step 1: Move the five sections under one heading**

Create `## Upstream-only procedures (not runnable from this fork)` at the end of the file and move the sections under it unchanged, each with one line naming what it needs (upstream's demo cluster, OpenBao, a Forgejo runner token, Harbor, in-cluster BuildBuddy). Remove the fast path's `global.imageTag` patch step, which `docs/RELEASE_PUBLISHING.md:173-174` forbids, or note the contradiction in that one line.

- [ ] **Step 2: Fix the link and the registry example**

`:757`: change the href to `docs/ci-schema-templates.md` (relative to `docs/`; the file is at `docs/docs/ci-schema-templates.md`). `:400`: `ghcr.io/jrmatherly/serviceradar-web-ng`.

- [ ] **Step 3: Update the pointer list**

`AGENTS.md:304-307` no longer lists the demo refresh, the release playbook or CNPG database access as live runbooks.

- [ ] **Step 4: Prove it**

Run: `grep -o '](docs/[^)]*)' docs/agent-runbooks.md | tr -d '](' | tr -d ')' | while read p; do [ -e "docs/$p" ] || echo "missing $p"; done` (prints `missing docs/docs/ci-schema-templates.md` today) and `grep -n 'registry.carverauto.dev' docs/agent-runbooks.md`.
Expected: no `missing` line; registry hits only below the new heading.

- [ ] **Step 5: Commit** as `docs(runbooks): separate upstream-only procedures`.

---

### Task 5: Fix the two false readings in make doctor

**Files:**
- Modify: `scripts/doctor.sh:84-86` (hooks path), `:73-78,153-156` (golangci label)

- [ ] **Step 1: Reproduce**

Run: `make doctor 2>&1 | grep -E 'hooks path|golangci'`
Expected: `FAIL git hooks path: make hooks-setup` although the config value resolves to the repo's `.githooks`; `WARN golangci-lint on PATH is v2.11.4` while `golangci-lint version --short` prints 2.15.0.

- [ ] **Step 2: Compare resolved paths against the common git dir**

`hooks_path_is_githooks` becomes `[ "$(realpath -q "$(git config core.hooksPath)")" = "$(realpath "$(git rev-parse --path-format=absolute --git-common-dir)/../.githooks")" ]`. The common dir is what makes it pass inside a worktree, where `git config core.hooksPath` returns the main checkout's absolute path while a plain `realpath .githooks` would be the worktree's own. `doctor.sh:10-11` already changes to the repo root; `realpath -q` exists in macOS `/bin`. The golangci label prints both the pinned and the found version.

- [ ] **Step 3: Prove it without touching the repo config**

Run: `make doctor 2>&1 | grep 'hooks path'` in the main checkout and in `.claude/worktrees/agent-a6afcb26ba5657ffb`, then `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp make doctor 2>&1 | grep 'hooks path'`.
Expected: PASS, PASS, FAIL.

- [ ] **Step 4: Commit** as `fix(doctor): resolve the hooks path before comparing`.

---

### Task 6: Enforce gofmt through golangci and format the 16 files

**Files:**
- Modify: `.golangci.yml` (add `formatters: enable: [gofmt]` and copy `linters.exclusions.paths` into `formatters.exclusions.paths`; `golangci-lint fmt` reads only the latter)
- Modify: the 15 files golangci flags on Linux (`go/pkg/db/interfaces.go`, `go/pkg/k8sinventory/{metrics,spool}.go`, `go/pkg/logger/errors.go`, nine under `go/pkg/models/`, `go/pkg/natsutil/events_test.go`, `go/pkg/scan/syn_scanner_test.go` which is `//go:build linux` and invisible to `run` on macOS) plus `go/tests/e2e/inventory/inventory_test.go` (build-tagged `e2e`, invisible to golangci everywhere)

- [ ] **Step 1: Add the block and watch the gate fail**

Run: `make lint-go`
Expected: exit 1 naming 14 files on macOS, 15 on Linux CI. If it passes, the formatter is not applied by `run` under this version; fall back to a `golangci-lint fmt --diff` step in `.github/workflows/golangci-lint.yml` before line 78 and in `make lint-go`.

- [ ] **Step 2: Format and prove it independent of build tags**

Run: `$(go env GOPATH)/bin/golangci-lint-v2.11.4/golangci-lint fmt $(go list -f '{{.Dir}}' ./go/... ./proto/...)` (it ignores build tags and reaches the scan file), `gofmt -s -w go/tests/e2e/inventory/inventory_test.go`, then `gofmt -s -l go proto | grep -v /vendor/`, `make lint-go`, `GOOS=linux go vet ./go/pkg/scan/`, `go test ./go/pkg/models/... ./go/pkg/scan/...`.
Expected: the `gofmt -s -l` line prints nothing (it prints the 16 files today); exit 0, exit 0, PASS.

- [ ] **Step 3: Commit** as `chore(go): enforce gofmt in the lint gate`.

---

### Task 7: Run the fork CI check and shellcheck in CI, and fix the three shell errors

**Files:**
- Modify: `.github/workflows/golangci-lint.yml` (a step before `golangci-lint` at line 78 that runs `scripts/ci/check-fork-ci.sh`; nothing runs that script today although `docs/fork-ci.md:9` calls it the acceptance check)
- Modify: `scripts/ci/check-fork-ci.sh` (add `shellcheck -S error scripts/*.sh scripts/ci/*.sh` next to actionlint at line 12)
- Modify: `scripts/reseed-kv-from-configmap.sh:15-25`, `scripts/setup-package.sh:535` (`return 0`), `scripts/build-images.sh:161` (only if the Dockerfile retirement has not deleted it)
- Modify: `docs/fork-ci.md` (the Workflows table row for `golangci-lint.yml` names the new step)

- [ ] **Step 1: Add the shellcheck pass and watch it fail**

Run: `scripts/ci/check-fork-ci.sh`
Expected: exit 1 with `SC2259` (reseed), `SC2104` (setup-package), `SC2145` (build-images).

- [ ] **Step 2: Fix the reseed script's lost stdin with the standard library only**

The kubectl output is piped into `python - <<'PY'`, and the heredoc replaces stdin; the script also calls `python` and imports `yaml`, which is not installed. Replace with `kubectl get configmap "$CONFIGMAP" -n "$NAMESPACE" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(sorted(k for k in d.get("data",{}) if k.endswith(".json"))))'`. Reproduce before and after with a fake `kubectl` executable first on `PATH` that prints a two-key ConfigMap as JSON.
Expected: before, an empty file list; after, two names.

- [ ] **Step 3: Fix the other two, wire the workflow step, re-run**

Run: `scripts/ci/check-fork-ci.sh && shellcheck -S warning scripts/reseed-kv-from-configmap.sh`
Expected: exit 0. The PR's own `lint` run must show the new step passing.

- [ ] **Step 4: Commit** as `chore(ci): run the fork CI check and shellcheck in the lint workflow`.

---

### Task 8: Align the OTP and TinyGo SDK pins

**Files:**
- Modify: `MODULE.bazel:176-197,952-954` (OTP 28.1 versions, URLs and the arm64 sha256; `:208` is `otp_major = "28"` and stays), `MODULE.bazel.lock:568-585` (the `otp_28_1` URLs, versions, strip_prefix and sha256s; release builds run with `--lockfile_mode=error`), `.github/workflows/palisade-publish.yml:69`
- Decide: keep the `otp_28_1*` repository names (used ten times: `MODULE.bazel:176,194,214,233-236,244-245,931`) or rename them to `otp_28_3*`; keeping them is the smaller diff
- Modify: `MODULE.bazel:688-692` and `build/wasm_plugins/tinygo_repo.bzl:46-52` (Go 1.25.5 for TinyGo, four archive sha256s)
- Modify: the seven `:gen` references listed in plan 1's constraints (`MODULE.bazel:151-152`, `elixir/README.md:179,541,577`, `elixir/palisade/BUILD.bazel:6`, `third_party/hex/bundlex.BUILD:5`, `third_party/hex_vendored/README.md:30`) to `:write`

- [ ] **Step 1: Artifacts and checksums**

The hex amd64 and arm64 `OTP-28.3.tar.gz`, the `erlang/otp` `otp_src_28.3.tar.gz` and the `go1.25.12` darwin-arm64 and linux-amd64 archives all return 200 (checked 2026-10-29). The hex sha256 values come from the same `builds.txt` the 28.1 pin was taken from; the darwin OTP source and the four Go archives need `shasum -a 256` on the downloaded file. Record every checksum in the PR body.

- [ ] **Step 2: Bump, regenerate the lock, build**

Set OTP 28.3 and Go 1.25.12 with their checksums. Run: `bazel mod deps --lockfile_mode=update && bazel build --config=remote //elixir/web-ng:all //build/wasm_plugins:opentext_nom_inventory_wasm //:images`.
Expected: exit 0. A failure on the opentext-nom module names whether `go 1.25.12` in its `go.mod` or the SDK is the mismatch. Re-read the comment at `elixir/serviceradar_core/lib/serviceradar/.../stream_load.ex:594`, which asserts an OTP 28.1 httpc retry behaviour, and confirm it under 28.3.

- [ ] **Step 3: Prove it**

Run: `grep -nE 'OTP-28\.1|"28\.1"|otp-version: .?28\.1' MODULE.bazel MODULE.bazel.lock .github/workflows/*.yml; grep -n '1\.25\.5' MODULE.bazel build/wasm_plugins/tinygo_repo.bzl; git grep -n 'third_party/hex:gen\b'`
Expected: no output from any of the three (a bare `28\.1` would match `bazelisk-version: 1.28.1` in `native-addons.yml:409`, which is why the pattern is anchored).

- [ ] **Step 4: Commit** as `chore(build): align the OTP and TinyGo SDK pins`.

---

### Task 9: Reclaim the merged worktrees (local, no PR)

- [ ] **Step 1: Confirm both are clean, merged, and hold no ignored state worth keeping**

Run: `git worktree list; for w in .claude/worktrees/*; do git -C $w status --short --ignored | head -20; done; git branch --merged origin/staging; du -sh .claude/worktrees/*`
Expected: no tracked changes; `frosty-maxwell-4307a4` lists ignored `tmp/`, `elixir/*/tmp/`, `priv/native/` and `.bazelrc.remote`, which `worktree remove` deletes; `fix/site-name-sweep`, `worktree-agent-a6afcb26ba5657ffb`, `claude/frosty-maxwell-4307a4` listed as merged; 4.1G and 9.0G.

- [ ] **Step 2: Remove**

Run: `git worktree remove .claude/worktrees/agent-a6afcb26ba5657ffb && git worktree remove .claude/worktrees/frosty-maxwell-4307a4 && git branch -d worktree-agent-a6afcb26ba5657ffb claude/frosty-maxwell-4307a4 fix/site-name-sweep`
Expected: 13 GB freed (`du -sh .claude/worktrees` before and after); `-d` refuses anything unmerged.

---

### Task 10: Owner decision on the docs site domain

**Files:**
- Modify: `docs/static/CNAME` (`docs.serviceradar.cloud`, upstream's domain), `docs/docusaurus.config.ts:14` (the same domain) and `:22,142,205,209` (organization and GitHub links)

- [ ] **Step 1: Owner decision**

The owner picks one: keep the docs site unpublished (record the decision in `docs/fork-ci.md` next to the known blocker), or publish under a fork-owned domain. Before publishing: `docs/docs` holds 16 `registry.carverauto.dev` lines across 8 files that the site would ship; they are upstream's published docs and need their own sweep first.

- [ ] **Step 2: Apply and build**

Run: `cd docs && sfw npm ci && sfw npm run build` and `grep -rnE 'serviceradar\.cloud|carverauto' docs/static/CNAME docs/docusaurus.config.ts`
Expected: exit 0; the grep prints nothing when publishing under a fork domain.

- [ ] **Step 3: Commit** as `docs(site): point the docs site at the fork's domain` or the fork-ci note.

## Appendix A. Alternatives rejected

- Keeping `RELEASE.md` and editing it. Two release docs drift; the fork already has the current one.
- A separate gofmt workflow step. golangci v2 runs formatters inside `run`, so the existing gate carries it.
- Lowering `opentext-nom/go.mod` to `1.25.5` instead of raising the SDK. The plugin requires `serviceradar-sdk-go/v2 v2.1.0`; check its own `go` line before choosing that direction.
- Switching the README to the OCI chart now. The package does not exist; the line would fail for every reader until the first release.

## Appendix B. Risks

- Task 8 changes the Erlang runtime inside the published core-elx and web-ng images and the Bazel lock. It needs the full image build in its Step 2 and a republish after merge.
- Task 6 may reformat generated protobuf code if the exclusions are not copied into `formatters.exclusions`; Step 1 of the task does that before formatting.
- Task 7 makes `check-fork-ci.sh` a CI step for the first time; any upstream-pattern hit it has been silently finding becomes a red `lint` check on the PR that wires it, which is the point.
