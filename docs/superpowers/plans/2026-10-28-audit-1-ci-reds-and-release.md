# CI reds and release blockers implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the daily Elixir advisory job green, keep the Rust advisory job green past its next run, make the first fork release able to publish, and move Go off a toolchain with 25 reachable standard-library advisories.

**Architecture:** Five pull requests against `staging`, one per red. Each dependency bump edits the lockfile, regenerates the Bazel mirror that the lockfile feeds, and ends with the same audit command CI runs. The two release fixes are one-line changes proven by a dry run. Each PR carries its own failing check first.

**Tech Stack:** Mix and Hex (`scripts/elixir_dep_audit.sh`), Cargo and RustSec (`cargo audit` 0.22.2), Bazel hex and crate mirrors (`//third_party/hex:write`, `//third_party/crate_mirror:sync`), Go 1.26 and govulncheck, GitHub Actions.

**Spec:** Tier 1 of `private/findings/2026-10-28-project-audit.md` (gitignored). Sibling plans: `2026-10-28-audit-2-security-defaults.md`, `2026-10-28-audit-3-captured-data.md`, `2026-10-28-audit-4-docs-and-hygiene.md`.

## Global constraints

- Never push to `staging`; push with `git push origin <local>:refs/heads/<branch>` (`AGENTS.md`).
- Prefix fetching package managers with `sfw` (`cargo`, `npm`); Mix, Go and Bazel are not wrapped (`AGENTS.md`).
- A `mix.lock` change is followed by `bazel run //third_party/hex:write` and `bazel test //third_party/hex:gen_test` (the `MODULE.bazel:151-152` comment names a `:gen` target that does not exist; use `:write`).
- A `Cargo.lock` change is followed by `bazel run //third_party/crate_mirror:sync` then `bazel build //rust/...`; a green `cargo check` does not prove Bazel (`.agents/skills/serviceradar-dependencies/SKILL.md`).
- Any `.github/` edit runs `scripts/ci/check-fork-ci.sh`; `release.yml` edits also run `bash scripts/test-release-publish-contracts.sh`.
- Remote Bazel needs `.bazelrc.remote` in the checkout and `--config=remote`.
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit.

## Review focus

- A `mix deps.update` that pulls `ash_sql` 0.8.4 alongside ash 3.37.2 and changes query SQL; Task 1 runs the core and web-ng suites, not only the audit.
- A tonic 0.14.8 bump that moves `tonic-prost-build` and regenerates protobuf glue differently; Task 2 builds every `//rust/...` target under Bazel.
- A `--repo` value that is empty when the workflow is dispatched from a fork of the fork; Task 3's dry run asserts the log line names `jrmatherly/serviceradar`.
- An authenticated GHCR probe for a missing chart that returns something other than 403 or 404; Task 4 records what the real registry says before choosing the accepted status.
- A `MODULE.bazel.lock` without the new Go SDK entry, which fails every `--lockfile_mode=error` release job; Task 5 refreshes the lock in the same PR.

## Dependency graph

Tasks 1 to 5 are independent and branch from `staging`. Land Task 1 and Task 2 first; they stop CI from going red. Task 3 and Task 4 can land in either order. Task 5 is largest and last.

---

### Task 1: Clear the Hex advisories that fail the daily audit

**Files:**
- Modify: `elixir/serviceradar_core/mix.exs:92` (`{:ash, "~> 3.34.6"}` becomes `"~> 3.37.2"`)
- Modify: `elixir/serviceradar_agent_gateway/mix.lock`, `elixir/serviceradar_core/mix.lock`, `elixir/serviceradar_core_elx/mix.lock`, `elixir/web-ng/mix.lock`
- Modify: `third_party/hex/hex_packages.bzl` and any `third_party/hex/*.BUILD` stub the writer regenerates
- Modify: `MODULE.bazel:151-152` (comment names `:write`)

**Interfaces:**
- Consumes: `scripts/elixir_dep_audit.sh --with-retired` (phase 2 runs `mix hex.audit` through `scripts/lib/hex-audit-filter.awk`); the per-project `.deps_audit_ignore` files stay as they are.
- Produces: locked versions bandit 1.14.1, ash 3.37.2, ash_postgres 2.15.2, plug_crypto 2.2.1, and jose 1.11.13 in web-ng. The targets come from osv.dev "fixed" ranges; bandit 1.14.0 is not enough because EEF-CVE-2026-116078 (published 2026-10-28) is fixed in 1.14.1.

- [ ] **Step 1: Reproduce the failure per project, read-only**

Run, for each of the four failing projects: `cd elixir/<p> && mix hex.audit 2>&1 | awk -v ignore_file=.deps_audit_ignore -f ../../scripts/lib/hex-audit-filter.awk; echo "exit=$?"`
Expected: `exit=1` for `serviceradar_agent_gateway`, `serviceradar_core`, `serviceradar_core_elx`, `web-ng`; web-ng lists 26 non-ignored advisories.

- [ ] **Step 2: Lift the ash constraint and update the locks**

Edit `serviceradar_core/mix.exs:92`. Then in each of the four projects run `mix deps.update ash ash_postgres bandit plug_crypto` (add `jose` in web-ng). The other three projects get ash through the `serviceradar_core` path dependency, so update core first. Record the resulting `ash_sql` version; if it moved past 0.8.0, say so in the PR body.

- [ ] **Step 3: Re-run the audit the way CI does**

Run: `./scripts/elixir_dep_audit.sh --with-retired`
Expected: exit 0 and the last line `all projects clean`.

- [ ] **Step 4: Regenerate the Bazel hex mirror and run its gate**

Run: `bazel run //third_party/hex:write && bazel test //third_party/hex:gen_test`
Expected: the writer rewrites the five tuples (ash, ash_postgres, bandit, jose, plug_crypto) in `hex_packages.bzl`; the test passes. Commit any `.BUILD` stubs it touched.

- [ ] **Step 5: Run the suites that the bumps can break**

Run: `make test-core-db` (core, needs the local test database per `docs/agent-runbooks.md`), `cd elixir/web-ng && mix test`, `cd elixir/serviceradar_agent_gateway && mix test`, `cd elixir/serviceradar_core_elx && mix test`.
Expected: 0 failures each. Record the counts in the PR body.

- [ ] **Step 6: Commit**

```bash
git add elixir/*/mix.exs elixir/*/mix.lock third_party/hex MODULE.bazel
git commit -m "fix(elixir): clear the hex advisories in bandit, ash, ash_postgres, plug_crypto and jose"
```

Then after merge: `gh workflow run elixir-dependency-audit.yml --ref staging` and watch it finish green.

---

### Task 2: Move tonic to 0.14.8 and clear the RustSec advisories

**Files:**
- Modify: `Cargo.lock` (tonic and its siblings to 0.14.8, zstd 0.14.3, zstd-safe 8.2.0, zstd-sys 2.1.2, pulldown-cmark 0.13.5, crypto-bigint 0.7.10)
- Modify: `rust/rdp-connector-probe/Cargo.lock` (crypto-bigint 0.7.10)
- Modify: `third_party/crate_mirror/` (synced archives and `BUILD.bazel`), `MODULE.bazel.lock` if the probe hub changes

**Interfaces:**
- Consumes: `make update-rust-deps` and `scripts/update-rust-bazel-deps.sh` (one package per invocation; the `workspace` mode does not move tonic, which is why the bumps are explicit).
- Produces: a lock where `cargo audit --deny warnings` with CI's ignore list at `rust-checks.yml:362-369` finds 0 vulnerabilities and 0 denied warnings, and the probe audit with its two ignores at `:333-335` finds none.

- [ ] **Step 1: Reproduce with a fresh advisory database**

Run: `git clone --depth 1 https://github.com/RustSec/advisory-db.git /tmp/rustsec && sfw cargo audit --db /tmp/rustsec --no-fetch --deny warnings --ignore RUSTSEC-2023-0071 --ignore RUSTSEC-2026-0235 --ignore RUSTSEC-2026-0367 --ignore RUSTSEC-2026-0368 --ignore RUSTSEC-2026-0369 --ignore RUSTSEC-2020-0016 --ignore RUSTSEC-2026-0249`
Expected: exit 1, 5 vulnerabilities (RUSTSEC-2026-0391, -0403, -0398, -0410, -0414) and 11 denied warnings.

- [ ] **Step 2: Bump the workspace lock**

Run: `sfw cargo update -p tonic -p tonic-health -p tonic-prost -p tonic-reflection -p tonic-types -p tonic-build -p tonic-prost-build -p pulldown-cmark -p crypto-bigint` then `sfw cargo check --workspace --lib --bins --tests --exclude rperf`.
Expected: tonic 0.14.8 brings zstd 0.14.3; check exits 0. If a tonic sibling refuses to move together, pin it with `--precise 0.14.8` and record why.

- [ ] **Step 3: Bump the probe lock**

Run: `cd rust/rdp-connector-probe && sfw cargo update -p crypto-bigint && sfw cargo check`
Expected: crypto-bigint 0.7.10 (0.7.5 to 0.7.8 are yanked); check exits 0.

- [ ] **Step 4: Re-run both audits**

Run the Step 1 command, and from `rust/rdp-connector-probe`: `sfw cargo audit --db /tmp/rustsec --no-fetch --deny warnings --ignore RUSTSEC-2023-0071 --ignore RUSTSEC-2023-0089`.
Expected: both exit 0.

- [ ] **Step 5: Sync the Bazel mirror and build**

Run: `bazel run //third_party/crate_mirror:sync && bazel build --config=remote //rust/... && bazel build --config=remote //rust/rdp-connector-probe/...`
Expected: exit 0. The root `Cargo.toml:247-248` annotates `zstd-sys` with `deps = ["zstd"]`; a failure there names the BCR C library, not the Rust crate.

- [ ] **Step 6: Run the Rust tests**

Run: `sfw cargo test --workspace --exclude rperf` and `bazel test --config=remote //rust/...`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Cargo.lock rust/rdp-connector-probe/Cargo.lock third_party/crate_mirror MODULE.bazel.lock
git commit -m "fix(rust): move tonic to 0.14.8 and clear the zstd, pulldown-cmark and crypto-bigint advisories"
```

Then after merge: `gh workflow run rust-checks.yml --ref staging` and watch the two audit steps pass.

---

### Task 3: Pass the repository to the release package publisher

**Files:**
- Modify: `.github/workflows/release.yml:937-939` (the `args` array)
- Modify: `docs/fork-ci.md:145` (one clause in the `release.yml` row)

**Interfaces:**
- Consumes: `build/release/publish_packages.go:217` `repoFlag := flag.String("repo", "carverauto/serviceradar", ...)`, validated at `:264-266` as `owner/repo`.
- Produces: `args+=("--repo" "${GITHUB_REPOSITORY}")` after the `--commit` line, matching how lines 175 and 498 already pass `--repository "${GITHUB_REPOSITORY}"` to other tools. No Go change: `parsePublishConfig` uses the global `flag` package and has no test; adding one is a refactor out of scope.

- [ ] **Step 1: Prove the default is upstream**

Run: `grep -n -- '--repo' .github/workflows/release.yml; grep -n 'flag.String("repo"' build/release/publish_packages.go`
Expected: the first prints nothing; the second prints line 217 with `"carverauto/serviceradar"`.

- [ ] **Step 2: Add the argument and the doc clause**

Insert the `args+=` line after line 939. In `docs/fork-ci.md:145` add "passes `--repo` from `GITHUB_REPOSITORY`".

- [ ] **Step 3: Run the fork CI checks**

Run: `scripts/ci/check-fork-ci.sh && bash scripts/test-release-publish-contracts.sh`
Expected: both exit 0.

- [ ] **Step 4: Prove it on a dry run**

Owner dispatch after merge (needs `PUBLISH_ENABLED` and a test tag per `docs/RELEASE_PUBLISHING.md`): `gh workflow run release.yml --ref <test tag> -f dry_run=true`. In the publish step log, the `publish_packages` repository line must read `jrmatherly/serviceradar`.
Expected: that log line; a line naming `carverauto/serviceradar` fails this task.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml docs/fork-ci.md
git commit -m "fix(release): publish packages to the repository running the workflow"
```

---

### Task 4: Make the release dry run pass when the chart package does not exist yet

**Files:**
- Modify: `scripts/check-oci-chart-version-available.sh:31-45` (status handling)
- Modify: `scripts/test-release-publish-contracts.sh` (the chart-script modes near lines 255-325; add a `denied` mode)
- Modify: `docs/RELEASE_PUBLISHING.md:57-58` (the dry run does contact the remote: a `git ls-remote` tag check and a Helm chart probe)

**Interfaces:**
- Consumes: `scripts/cut-release.sh:194`, which calls the chart check unconditionally before the dry-run branch at `:196`; `release.yml` lines ~820-862, which log in with `CHART_OCI_TOKEN` before calling the same script.
- Produces: the script treats an anonymous `403 ... denied` from `ghcr.io/token` as "no such package" only when no registry login is present (`helm registry login` state is readable from `~/.config/helm/registry/config.json`, or the script takes an explicit `--anonymous-ok` flag that `cut-release.sh` passes for dry runs). The accepted status for the authenticated CI probe is recorded in Step 2 before any code moves.

- [ ] **Step 1: Reproduce**

Run: `scripts/cut-release.sh --version 1.4.98 --dry-run --skip-changelog-check; echo "exit=$?"`
Expected: `exit=2` and stderr `Unable to verify OCI Helm chart occupancy ... response status code 403: denied`.

- [ ] **Step 2: Record what an authenticated probe of a missing package returns**

Run: `echo "$GITHUB_TOKEN" | helm registry login ghcr.io -u jrmatherly --password-stdin && helm show chart oci://ghcr.io/jrmatherly/charts/serviceradar --version 1.4.98; echo "exit=$?"; helm registry logout ghcr.io`
Expected: a status line to paste into the PR body. If it is `404`/`name unknown`, the existing regex at line 42 needs `name unknown` added and the anonymous case is the only change. If it is still `403`, the script must accept 403 as "absent" for both paths and the PR body says so.

- [ ] **Step 3: Write the failing contract test**

Add a `denied` mode to the fake Helm runner in `scripts/test-release-publish-contracts.sh` whose stderr is the GHCR 403 text; assert the script exits 0 and prints "no chart found".
Run: `bash scripts/test-release-publish-contracts.sh`
Expected: FAIL on the new case.

- [ ] **Step 4: Implement and re-run**

Run: `bash scripts/test-release-publish-contracts.sh && scripts/cut-release.sh --version 1.4.98 --dry-run --skip-changelog-check; echo "exit=$?"`
Expected: contracts PASS; `exit=0`. The `unavailable` mode (`dial tcp`) must still exit non-zero.

- [ ] **Step 5: Fix the doc sentence**

`docs/RELEASE_PUBLISHING.md:57-58` says the dry run does not contact the remote; replace with the two remote checks it performs.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-oci-chart-version-available.sh scripts/test-release-publish-contracts.sh docs/RELEASE_PUBLISHING.md
git commit -m "fix(release): treat a missing chart package as available in the dry run"
```

---

### Task 5: Move Go to 1.26.10 and add a scheduled govulncheck

**Files:**
- Modify: `go.mod:3` (`go 1.26.10`), `go.mod:47` and `go.sum` (`golang.org/x/net` v0.60.0 or newer), `.tool-versions:3`, `docker/rpm/Dockerfile.rpm.simple:16`
- Modify: `MODULE.bazel.lock` (new `go_sdk` index entry; `go_sdk.from_file` at `MODULE.bazel:685-688` follows `go.mod`)
- Create: `.github/workflows/govulncheck.yml`

**Interfaces:**
- Consumes: `.github/workflows/golangci-lint.yml` as the pattern (`setup-go` with `go-version-file: go.mod`, the `go mod download` retry loop). The job name `lint` is a required check in ruleset 25662015; the new workflow uses a different job name and runs on a weekly cron plus dispatch, like `rust-checks.yml` (`17 5 * * 1`), so a daily database change does not block unrelated PRs.
- Produces: `govulncheck ./...` exit 0 at the repo root under Go 1.26.10.

- [ ] **Step 1: Reproduce**

Run: `govulncheck ./...; echo "exit=$?"`
Expected: `exit=3`, "Your code is affected by 25 vulnerabilities from the Go standard library"; GO-2026-6809 (crypto/x509) is the one that needs 1.26.10, the rest are fixed at or below 1.26.9.

- [ ] **Step 2: Bump the toolchain and x/net**

Edit the four pins. Run: `go get golang.org/x/net@latest && go mod tidy` then `mise install golang` so the local toolchain matches.
Expected: `go version` prints go1.26.10.

- [ ] **Step 3: Refresh the Bazel lock**

Run: `bazel mod deps --lockfile_mode=update && grep -c '1\.26\.10' MODULE.bazel.lock`
Expected: a count above 0. Release workflows run with `--lockfile_mode=error` and fail on a stale lock (`docs/RELEASE_PUBLISHING.md:37-45`).

- [ ] **Step 4: Prove the vulnerabilities are gone and the build holds**

Run: `govulncheck ./...; echo "exit=$?"` then `go build ./... && go test ./go/...` and `bazel build --config=remote //go/... //:images`.
Expected: `exit=0`; builds and tests pass. `//:images` proves the Bazel SDK switch reaches the published images.

- [ ] **Step 5: Write the scheduled workflow**

`govulncheck.yml`: `on: schedule` (Monday) and `workflow_dispatch`; one job `govulncheck` on `ubuntu-24.04`; `setup-go` with `go-version-file: go.mod`; `go install golang.org/x/vuln/cmd/govulncheck@v1.9.0`; `govulncheck ./...`. Run `scripts/ci/check-fork-ci.sh`.
Expected: exit 0. Dispatch once after merge and confirm it is green.

- [ ] **Step 6: Commit**

```bash
git add go.mod go.sum .tool-versions docker/rpm/Dockerfile.rpm.simple MODULE.bazel.lock .github/workflows/govulncheck.yml
git commit -m "chore(go): move to go 1.26.10 and add a scheduled govulncheck"
```

## Appendix A. Alternatives rejected

- Ignoring the bandit, ash and jose advisories in `.deps_audit_ignore`. Every one has a released fix, so the ignore list is for esaml only, where no fix exists.
- Pinning tonic at 0.14.6 and ignoring the zstd advisories. zstd is a runtime decompressor on the gRPC path of every addon; the fix is one minor release away.
- Reading `GITHUB_REPOSITORY` inside `publish_packages.go`. The workflow already passes the repository explicitly to two other tools, and a Go change would need a test harness the file does not have.
- Making govulncheck a PR gate. The database changes daily and would block unrelated PRs; the weekly cron matches the Rust audit.

## Appendix B. Risks

- Task 1 moves ash three minor versions in the core; Ash changes query generation between minors, which is why Step 5 runs the DB-backed core suite and not only the audit.
- Task 2 regenerates the crate mirror (about 1 GB download) and may touch `MODULE.bazel.lock`; review that diff for anything beyond the named crates.
- Task 5 changes the Go SDK inside every published Go image; it needs a publish after merge, which is the owner's dispatch.
