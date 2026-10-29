# Docs and hygiene implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the fork's documents and agent instructions from sending a reader to upstream's registry, forge or cluster, and put a gate behind the three local checks that fail with nobody watching.

**Architecture:** Docs tasks rewrite or mark upstream-only text so every instruction a reader can follow works on this fork. Gate tasks add the missing check to an existing lint path (`make lint-go`, `scripts/ci/check-fork-ci.sh`) and fix what it flags in the same PR, so the gate is proven to fail before it is proven to pass. One PR per task.

**Tech Stack:** Markdown, golangci-lint 2.11.4 (pinned in `Makefile:28-30`), shellcheck, Bazel `MODULE.bazel` pins, mise.

**Spec:** Tiers 4 and 5 of `private/findings/2026-10-28-project-audit.md` (gitignored). The Dockerfile build-path retirement is a separate proposed session and owns `docker/LOCAL_BUILD.md`, `scripts/build-images.sh` and `scripts/docker-login.sh`; this plan does not touch them. The upstream review backlog is a run of the `upstream-review` skill, not a task here.

## Global constraints

- Markdown under `docs/` is ASCII only (`AGENTS.md`). No long dashes anywhere.
- Historical records keep upstream references: `CHANGELOG`, `openspec/changes/archive/`, `docs/learnings/adlr/`, and fixtures that exercise the Forgejo release path (`AGENTS.md`).
- Forgejo issue numbers do not map to GitHub numbers; drop a link rather than swap the host.
- The fork's chart lives at `oci://ghcr.io/jrmatherly/charts/serviceradar` (`docs/fork-ci.md:79`, `OCI_CHART_REPOSITORY` default `<owner>/charts`); images at `ghcr.io/jrmatherly/serviceradar-*`; the cosign key is `docs/cosign.pub`.
- `.github/` changes run `scripts/ci/check-fork-ci.sh`.
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit.

## Review focus

- A reader of `README.md` who runs the Helm install line and gets a pull error from upstream's retired registry (Task 2).
- An agent that reads `AGENTS.md:83-90` and files a PR against upstream (Task 1).
- A gofmt formatter block that also reformats vendored or generated files; Task 6 checks the exclusion paths before committing.
- A shellcheck gate that fails on upstream-authored scripts the fork never runs; Task 7 scopes to `scripts/*.sh` and `scripts/ci/*.sh` and records the three error-level findings it fixes.
- An OTP bump in `MODULE.bazel` with no matching prebuilt archive; Task 8 proves the download URLs resolve before editing.

## Dependency graph

All tasks are independent and branch from `staging`, except Task 3 which rebases onto Task 2 if both touch `README.md`. Tasks 1 to 4 and 10 are docs. Tasks 5 to 8 are gates and pins. Task 9 is local-only and produces no PR.

---

### Task 1: Point the collaboration-host rule at this fork

**Files:**
- Modify: `AGENTS.md:83-90` and the overview lines at `246`, `251`, `313`

- [ ] **Step 1: Rewrite the hard rule**

Replace "for `carverauto/serviceradar` go through `gh` against <https://github.com/carverauto/serviceradar>" with "for this repository go through `gh` against its `origin` (`jrmatherly/serviceradar`); upstream is `carverauto/serviceradar` and receives nothing unless the owner says so". Keep the two Forgejo sub-bullets.

- [ ] **Step 2: Check the overview lines**

Line 246 names a Next.js web UI; line 251 lists Go packages; line 313 the `.bazelrc.remote` rule. Verify each against the tree (`ls elixir/web-ng`, `ls go/pkg`, `ls .bazelrc.remote`) and correct what is false. Record what was true as "checked, unchanged".

- [ ] **Step 3: Prove it**

Run: `grep -n 'carverauto/serviceradar' AGENTS.md`
Expected: only lines that name upstream as upstream.

- [ ] **Step 4: Commit** as `docs(agents): name the fork as the collaboration host`.

---

### Task 2: Replace upstream's registry in the README install and verify sections

**Files:**
- Modify: `README.md:101` (clone URL), `:116-130` (Helm), `:162-198` (cosign), `:206-225` (chart URL, pull secret, ArgoCD repo URL)

- [ ] **Step 1: Rewrite with the fork's values**

Clone `https://github.com/jrmatherly/serviceradar.git` (as `BUILD.md:48` already does). Helm commands against `oci://ghcr.io/jrmatherly/charts/serviceradar`. Cosign: `cosign verify --key docs/cosign.pub ghcr.io/jrmatherly/serviceradar-core-elx:<tag>`; drop the keyless-identity variant at 190-198 unless `docs/fork-ci.md` says the fork signs keyless (it signs with `COSIGN_PRIVATE_KEY`). The pull secret paragraph at 210 goes, GHCR packages are public.

- [ ] **Step 2: Run the verify line against a real tag**

Run: `cosign verify --key docs/cosign.pub ghcr.io/jrmatherly/serviceradar-core-elx:latest | head -3`
Expected: a verified signature block. This is the line the README now prints, so it must work.

- [ ] **Step 3: Prove it**

Run: `grep -n 'registry.carverauto.dev\|carverauto/serviceradar.git' README.md`
Expected: no output.

- [ ] **Step 4: Commit** as `docs(readme): install and verify against the fork's registry`.

---

### Task 3: Retire the Harbor and Forgejo release docs

**Files:**
- Delete: `RELEASE.md` (158 lines, Harbor and Forgejo throughout; `docs/RELEASE_PUBLISHING.md` is the fork's current doc)
- Modify: `GOVERNANCE.md:47` and `docs/LF/LF_Github_Recommendations.md:36` (links to it), `build/ci/detect_docs_only_test.py:39` (lists it as a docs-only path)
- Modify: `docker/README.md:63-69` (multi-arch claim, two registry examples, "published to Harbor")
- Modify: `openspec/AGENTS.md:404,434-464` (`cut-release.sh --push` triggers a release; chart URL)
- Modify: `docs/RELEASE_PUBLISHING.md:27-29` (unconditional demo-branch advance)

- [ ] **Step 1: Confirm `RELEASE.md` has nothing `docs/RELEASE_PUBLISHING.md` lacks**

Read both. Move any surviving fact (a flag, an env var) into the newer doc, then delete the old one and repoint the two links.

- [ ] **Step 2: Fix the three other docs**

`docker/README.md`: images are amd64 (`docker-compose.arm64.yml:5`), examples use `ghcr.io/jrmatherly/...`, published by `publish-oci.yml` and `release.yml`. `openspec/AGENTS.md`: `cut-release.sh --push` pushes the branch; the tag push by the owner triggers `release.yml`; chart URL is the fork's. `RELEASE_PUBLISHING.md:27-29`: mark the demo-branch advance as upstream's step.

- [ ] **Step 3: Prove it**

Run: `python3 -m pytest build/ci/detect_docs_only_test.py -q` and `git grep -n 'registry.carverauto.dev\|code.carverauto.dev' -- README.md RELEASE.md docker/README.md openspec/AGENTS.md docs/RELEASE_PUBLISHING.md`
Expected: tests pass; grep prints nothing.

- [ ] **Step 4: Commit** as `docs(release): drop the harbor and forgejo release guide`.

---

### Task 4: Mark upstream-only runbooks and fix the broken link

**Files:**
- Modify: `docs/agent-runbooks.md:23-69` (demo Helm refresh and fast path), `:539-558` (release playbook), `:560-642` (CNPG access on upstream's staging cluster), `:818` (hosted-Bazel dispatches), `:757` (link)
- Modify: `AGENTS.md:304-307` (the runbook list)

- [ ] **Step 1: Move the four sections under one heading**

Create `## Upstream-only procedures (not runnable from this fork)` at the end of the file and move the four sections under it unchanged, each with one line naming what it needs (upstream's demo cluster, OpenBao, a Forgejo runner token, Harbor). Remove the fast path's `global.imageTag` patch step, which `docs/RELEASE_PUBLISHING.md:173-174` forbids, or note the contradiction in that one line.

- [ ] **Step 2: Fix the link**

`docs/agent-runbooks.md:757`: change the href to `docs/ci-schema-templates.md` (relative to `docs/`; the file is at `docs/docs/ci-schema-templates.md`).

- [ ] **Step 3: Update the pointer list**

`AGENTS.md:304-307` no longer lists the demo refresh and release playbook as live runbooks.

- [ ] **Step 4: Prove it**

Run a relative-link check over the file: `grep -o '](docs/[^)]*)' docs/agent-runbooks.md | tr -d '](' | tr -d ')' | while read p; do [ -e "docs/$p" ] || echo "missing $p"; done`
Expected: no output.

- [ ] **Step 5: Commit** as `docs(runbooks): separate upstream-only procedures`.

---

### Task 5: Fix the two false readings in make doctor

**Files:**
- Modify: `scripts/doctor.sh:84-86` (hooks path), `:73-78,153-156` (golangci label)

- [ ] **Step 1: Reproduce**

Run: `make doctor 2>&1 | grep -E 'hooks path|golangci'`
Expected: `FAIL` on hooks path although `git config core.hooksPath` resolves to the repo's `.githooks`; the golangci line prints the wanted version, not the found one.

- [ ] **Step 2: Compare resolved paths**

`hooks_path_is_githooks` becomes `[ "$(cd "$(git rev-parse --show-toplevel)" && realpath -q "$(git config core.hooksPath)")" = "$(realpath .githooks)" ]`. The golangci label prints both the pinned and the found version.

- [ ] **Step 3: Prove it**

Run: `make doctor 2>&1 | grep -E 'hooks path|golangci'` with the absolute config, then with `git config core.hooksPath .githooks`, then with a wrong value `git config core.hooksPath /tmp` restored afterwards.
Expected: PASS, PASS, FAIL.

- [ ] **Step 4: Commit** as `fix(doctor): resolve the hooks path before comparing`.

---

### Task 6: Enforce gofmt through golangci and format the 16 files

**Files:**
- Modify: `.golangci.yml` (add `formatters: enable: [gofmt]`)
- Modify: the 15 first-party files golangci flags (`go/pkg/db/interfaces.go`, `go/pkg/k8sinventory/{metrics,spool}.go`, `go/pkg/logger/errors.go`, nine under `go/pkg/models/`, `go/pkg/natsutil/events_test.go`, `go/pkg/scan/syn_scanner_test.go`) plus `go/tests/e2e/inventory/inventory_test.go` (build-tagged, invisible to golangci)

- [ ] **Step 1: Add the block and watch the gate fail**

Run: `make lint-go`
Expected: exit 1 naming the 15 files. If it passes, the formatter is not applied by `run` under this version; fall back to a `golangci-lint fmt --diff` step in `.github/workflows/golangci-lint.yml` before line 78 and in `make lint-go`.

- [ ] **Step 2: Check exclusions**

Run: `grep -n -A8 'exclusions' .golangci.yml` and confirm vendored and generated paths are excluded for formatters as well as linters.

- [ ] **Step 3: Format**

Run: `$(go env GOPATH)/bin/golangci-lint-v2.11.4/golangci-lint fmt $(go list -f '{{.Dir}}' ./go/... ./proto/...)` and `gofmt -s -w go/tests/e2e/inventory/inventory_test.go`, then `make lint-go` and `go test ./go/pkg/models/... ./go/pkg/scan/...`.
Expected: exit 0, PASS.

- [ ] **Step 4: Commit** as `chore(go): enforce gofmt in the lint gate`.

---

### Task 7: Lint the shell scripts in CI and fix the three errors

**Files:**
- Modify: `scripts/ci/check-fork-ci.sh` (add a shellcheck pass over `scripts/*.sh scripts/ci/*.sh` at severity `error`, next to actionlint at line 13)
- Modify: `scripts/reseed-kv-from-configmap.sh:15-25`, `scripts/setup-package.sh:535`, `scripts/build-images.sh:161` (the last only if the Dockerfile retirement has not deleted it)

- [ ] **Step 1: Watch it fail**

Run: `scripts/ci/check-fork-ci.sh`
Expected: exit 1 with `SC2259`, `SC2104`, `SC2145`.

- [ ] **Step 2: Fix the reseed script's lost stdin**

The kubectl output is piped into `python - <<'PY'`, and the heredoc replaces stdin. Pass the YAML through a file descriptor or a variable: `kubectl ... -o yaml | python3 -c "$PY_SCRIPT"` with the script in a variable, and call `python3`. Reproduce before and after with a fake `kubectl` function that prints a two-key ConfigMap.
Expected: before, an empty file list; after, two names.

- [ ] **Step 3: Fix the other two and re-run**

Run: `scripts/ci/check-fork-ci.sh && shellcheck -S warning scripts/reseed-kv-from-configmap.sh`
Expected: exit 0.

- [ ] **Step 4: Commit** as `chore(scripts): lint shell scripts in the fork CI check`.

---

### Task 8: Align the OTP and TinyGo SDK pins

**Files:**
- Modify: `MODULE.bazel:176-197,208,953-954` (OTP 28.1 in four places), `.github/workflows/palisade-publish.yml:69`
- Modify: `MODULE.bazel:688-692` and `build/wasm_plugins/tinygo_repo.bzl:46` (Go 1.25.5 for TinyGo) or `go/cmd/wasm-plugins/opentext-nom/go.mod:3` (`go 1.25.12`)

- [ ] **Step 1: Prove the artifacts exist before editing**

Run: `curl -sI <the hex prebuilt URL pattern from MODULE.bazel with 28.3> | head -1` and the arm64 `OTP-28.3.tar.gz` URL, and `curl -sI https://go.dev/dl/go1.25.12.darwin-arm64.tar.gz | head -1`.
Expected: `200` for each. A `404` stops the task with that fact.

- [ ] **Step 2: Bump and build**

Set OTP to 28.3 everywhere (`.tool-versions` and `elixir-quality.yml` already say 28.3) and the TinyGo Go SDK to 1.25.12 with its sha256 values. Run: `bazel build --config=remote //elixir/web-ng:all //build/wasm_plugins:opentext_nom_inventory_wasm`.
Expected: exit 0. A failure on the opentext-nom module names whether `go 1.25.12` in its `go.mod` or the SDK is the mismatch.

- [ ] **Step 3: Prove it**

Run: `grep -n '28\.1\b' MODULE.bazel .github/workflows/*.yml; grep -n '1\.25\.5' MODULE.bazel build/wasm_plugins/tinygo_repo.bzl`
Expected: no output.

- [ ] **Step 4: Commit** as `chore(build): align the OTP and TinyGo SDK pins`.

---

### Task 9: Reclaim the merged worktrees (local, no PR)

- [ ] **Step 1: Confirm both are clean and merged**

Run: `git worktree list; for w in .claude/worktrees/*; do git -C $w status --short | wc -l; done; git branch --merged origin/staging`
Expected: 0 and 0; `fix/site-name-sweep`, `worktree-agent-a6afcb26ba5657ffb`, `claude/frosty-maxwell-4307a4` listed.

- [ ] **Step 2: Remove**

Run: `git worktree remove .claude/worktrees/agent-a6afcb26ba5657ffb && git worktree remove .claude/worktrees/frosty-maxwell-4307a4 && git branch -d worktree-agent-a6afcb26ba5657ffb claude/frosty-maxwell-4307a4 fix/site-name-sweep`
Expected: 13 GB freed (`du -sh .claude/worktrees` before and after); `-d` refuses anything unmerged.

### Task 10: Owner decision on the docs site domain

**Files:**
- Modify: `docs/static/CNAME`, `docs/docusaurus.config.ts` (both name upstream's domain; `docs/fork-ci.md` lists this under known blockers)

- [ ] **Step 1: Owner decision**

The owner picks one: keep the docs site unpublished (then disable or leave `docs-pages.yml` as it is and record the decision in `docs/fork-ci.md`), or publish under a fork-owned domain (then set `CNAME` and the `url` and `baseUrl` fields to it).

- [ ] **Step 2: Apply and build**

Run: `cd docs && npm run build`
Expected: exit 0; `grep -rn 'carverauto' docs/static/CNAME docs/docusaurus.config.ts` prints nothing when publishing.

- [ ] **Step 3: Commit** as `docs(site): point the docs site at the fork's domain` or the fork-ci note.

## Appendix A. Alternatives rejected

- Keeping `RELEASE.md` and editing it. Two release docs drift; the fork already has the current one.
- A separate gofmt workflow step. golangci v2 runs formatters inside `run`, so the existing gate carries it.
- Lowering `opentext-nom/go.mod` to `1.25.5` instead of raising the SDK. The plugin requires `serviceradar-sdk-go/v2 v2.1.0`; check its own `go` line before choosing that direction.

## Appendix B. Risks

- Task 8 changes the Erlang runtime inside the published core-elx and web-ng images. It needs a full `bazel build //:images` and a compose bring-up before it merges, and a republish after.
- Task 6 may reformat generated protobuf code if the exclusions are wrong; the Step 2 check guards it.
