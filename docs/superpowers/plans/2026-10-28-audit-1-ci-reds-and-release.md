# CI reds and release blockers implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the daily Elixir advisory job green, keep the Rust advisory job green past its next run, make the first fork release able to publish, and move Go off a toolchain with 25 reachable standard-library advisories.

**Architecture:** Five pull requests against `staging`, one per red. Each dependency bump edits the lockfile, regenerates the Bazel mirror that the lockfile feeds, and ends with the same audit command CI runs. The two release fixes are small changes proven by a contract test and a dry run of the script, never by a dispatch of the release workflow. Each PR carries its own failing check first.

**Tech Stack:** Mix and Hex (`scripts/elixir_dep_audit.sh`), Cargo and RustSec (`cargo audit` 0.22.2), Bazel hex and crate mirrors (`//third_party/hex:write`, `//third_party/crate_mirror:sync`), Go 1.26 and govulncheck, GitHub Actions.

**Spec:** Tier 1 of `private/findings/2026-10-28-project-audit.md` (gitignored). Sibling plans: `2026-10-28-audit-2-security-defaults.md`, `2026-10-28-audit-3-captured-data.md`, `2026-10-28-audit-4-docs-and-hygiene.md`.

## Global constraints

- Never push to `staging`; push with `git push origin <local>:refs/heads/<branch>` (`AGENTS.md`).
- Prefix fetching package managers with `sfw` (`cargo`, `npm`); Mix, Go and Bazel are not wrapped (`AGENTS.md`).
- A `mix.lock` change is followed by `bazel run //third_party/hex:write` and `bazel test //third_party/hex:gen_test`. Seven places name a `:gen` target that does not exist (`MODULE.bazel:151-152`, `elixir/README.md:179,541,577`, `elixir/palisade/BUILD.bazel:6`, `third_party/hex/bundlex.BUILD:5`, `third_party/hex_vendored/README.md:30`); plan 4 fixes them, this plan uses `:write`.
- A `Cargo.lock` change is followed by `bazel run //third_party/crate_mirror:sync` then `bazel build //rust/...`; a green `cargo check` does not prove Bazel (`.agents/skills/serviceradar-dependencies/SKILL.md`).
- Any `.github/` edit runs `scripts/ci/check-fork-ci.sh`; `release.yml` edits also run `bash scripts/test-release-publish-contracts.sh`. A new workflow is classified in the `docs/fork-ci.md` Workflows table (`:130-160`).
- Never dispatch `release.yml` to test a change. Its `dry_run` input reaches only `publish_packages` and the finalizers (`release.yml:951,1010`); "Publish container images" (`:724`) and "Publish Helm chart to OCI registry" (`:819`) have no guard, and any `v*` tag starts a full release (`:17-20`).
- Remote Bazel needs `.bazelrc.remote` in the checkout and `--config=remote`.
- A PR that adds or changes a test records `test-audit: not available` in its body (`AGENTS.md`).
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit.

## Review focus

- A Hex resolution that pulls `ash_sql` 0.8.4 alongside ash 3.37.2 and changes query SQL; Task 1 runs the core unit and integration suites, not only the audit.
- A tonic 0.14.8 bump that moves `tonic-prost-build` and regenerates protobuf glue differently; Task 2 builds every `//rust/...` target under Bazel.
- A chart check that fails open: Task 4 keeps the authenticated CI probe closed on 403 and opens only the explicit local flag.
- A `MODULE.bazel.lock` without the new Go SDK entry, which fails every `--lockfile_mode=error` release job; Task 5 refreshes the lock in the same PR.
- An x/net bump that drags other `golang.org/x` modules into `go.sum` and the Bazel lock; Task 5 pins the fixed version instead of `@latest`.

## Dependency graph

Tasks 1 to 5 are independent and branch from `staging`. Land Task 1 and Task 2 first; they stop CI from going red. Task 3 and Task 4 can land in either order. Task 5 is largest and last.

---

### Task 1: Clear the Hex advisories that fail the daily audit

**Files:**
- Modify: `elixir/serviceradar_core/mix.exs:85-97` (`{:ash, "~> 3.34.6"}` becomes `"~> 3.37.2"`, `{:ash_postgres, "~> 2.14"}` becomes `"~> 2.15.2"`, and the comments above them that list the fixed advisories and the "2.14 matches Ash 3.34" sentence)
- Modify: `elixir/serviceradar_agent_gateway/mix.lock`, `elixir/serviceradar_core/mix.lock`, `elixir/serviceradar_core_elx/mix.lock`, `elixir/web-ng/mix.lock`
- Modify: `third_party/hex/hex_packages.bzl` and any `third_party/hex/*.BUILD` stub the writer regenerates

**Interfaces:**
- Consumes: `scripts/elixir_dep_audit.sh --with-retired` (phase 2 runs `mix hex.audit` through `scripts/lib/hex-audit-filter.awk`; the daily failure is in that phase, not in mix_audit). The per-project `.deps_audit_ignore` files stay as they are.
- Produces: locked versions bandit 1.14.1, ash 3.37.2, ash_postgres 2.15.2, ash_sql 0.8.4 or newer (ash_postgres 2.15.2 requires it), plug_crypto 2.2.1, and jose 1.11.13 in web-ng. bandit 1.14.0 is not enough: EEF-CVE-2026-116078 (published 2026-10-28) is fixed in 1.14.1.

- [ ] **Step 1: Reproduce the failure per project, read-only**

Run, for each of the four failing projects: `cd elixir/<p> && mix deps.get >/dev/null && mix hex.audit 2>&1 | awk -v ignore_file=.deps_audit_ignore -f ../../scripts/lib/hex-audit-filter.awk; echo "exit=$?"`
Expected: `exit=1` for `serviceradar_agent_gateway`, `serviceradar_core`, `serviceradar_core_elx`, `web-ng`, and every unignored advisory names one of ash, ash_postgres, bandit, jose or plug_crypto.

- [ ] **Step 2: Lift the constraints and update the locks, core first**

Edit `serviceradar_core/mix.exs`. Then: `cd elixir/serviceradar_core && mix deps.update ash ash_postgres ash_sql plug_crypto` (core has no bandit in its lock, and `mix deps.update` raises on an unknown dependency); `cd elixir/serviceradar_agent_gateway && mix deps.update ash ash_postgres ash_sql bandit plug_crypto`; the same in `serviceradar_core_elx`; `cd elixir/web-ng && mix deps.update ash ash_postgres ash_sql bandit plug_crypto jose`. The other three reach ash through the `serviceradar_core` path dependency. If Hex pulls further Ash extensions (ash_oban, ash_phoenix, ash_ai) to satisfy 3.37, record the versions in the PR body.

- [ ] **Step 3: Re-run the audit the way CI does**

Run: `./scripts/elixir_dep_audit.sh --with-retired`
Expected: exit 0 and the last line `all projects clean`.

- [ ] **Step 4: Regenerate the Bazel hex mirror and run its gate**

Run: `bazel run //third_party/hex:write && bazel test //third_party/hex:gen_test`
Expected: the writer rewrites the ash, ash_postgres, ash_sql, bandit, jose and plug_crypto tuples in `hex_packages.bzl`; the test passes. Commit any `.BUILD` stubs it touched.

- [ ] **Step 5: Run the suites that the bumps can break**

Run: `make test-db-up && make test-db-migrate && make test-core-db` (the integration tier only; `Makefile:230` sets `SERVICERADAR_ONLY_INTEGRATION=1`), `bazel test --config=remote //elixir/serviceradar_core:unit_tests` (the roughly 2,700 unit tests), `cd elixir/web-ng && <env block from elixir/web-ng/AGENTS.md> mix test`, `cd elixir/serviceradar_agent_gateway && mix test`, `cd elixir/serviceradar_core_elx && mix test`.
Expected: 0 failures each, and no `Skipping web-ng tests` line. Record the counts in the PR body.

- [ ] **Step 6: Prove it in CI before merge**

The workflow's `pull_request` paths exclude `mix.lock` (`elixir-dependency-audit.yml:39-44`), so the PR never runs it.
Run: `gh workflow run elixir-dependency-audit.yml --ref <branch> -f with_retired=true` and watch it.
Expected: conclusion `success` on the branch.

- [ ] **Step 7: Commit**

```bash
git add elixir/*/mix.exs elixir/*/mix.lock third_party/hex
git commit -m "fix(elixir): clear the hex advisories in bandit, ash, ash_postgres, plug_crypto and jose"
```

---

### Task 2: Move tonic to 0.14.8 and clear the RustSec advisories

**Files:**
- Modify: `Cargo.lock` (tonic, tonic-health, tonic-prost, tonic-reflection, tonic-build, tonic-prost-build to 0.14.8; zstd 0.14.3, zstd-safe 8.2.0, zstd-sys 2.1.2; pulldown-cmark 0.13.5; crypto-bigint 0.7.10). `tonic-types` is declared at `Cargo.toml:205` but absent from the lock, so it is not in the update list.
- Modify: `rust/rdp-connector-probe/Cargo.lock` (crypto-bigint 0.7.10)
- Modify: `third_party/crate_mirror/` (synced archives and `BUILD.bazel`; the sync also covers the probe lock, `sync.py:40-52`), `MODULE.bazel.lock` if the probe hub changes

**Interfaces:**
- Produces: a lock where `cargo audit --deny warnings` with CI's ignore list at `rust-checks.yml:362-369` finds 0 vulnerabilities and 0 denied warnings, and the probe audit with its two ignores at `:333-335` finds none. zstd-sys 2.1.2 still bundles libzstd 1.5.7, which matches `bazel_dep zstd 1.5.7.bcr.1` at `MODULE.bazel:41`, so `MODULE.bazel` itself does not change.

- [ ] **Step 1: Reproduce with a fresh advisory database**

Run: `git clone --depth 1 https://github.com/RustSec/advisory-db.git /tmp/rustsec && sfw cargo audit --db /tmp/rustsec --no-fetch --deny warnings --ignore RUSTSEC-2023-0071 --ignore RUSTSEC-2026-0235 --ignore RUSTSEC-2026-0367 --ignore RUSTSEC-2026-0368 --ignore RUSTSEC-2026-0369 --ignore RUSTSEC-2020-0016 --ignore RUSTSEC-2026-0249`
Expected: exit 1, 5 vulnerabilities (RUSTSEC-2026-0391, -0403, -0398, -0410, -0414) and 11 denied warnings.

- [ ] **Step 2: Bump the workspace lock**

Run: `sfw cargo update -p tonic -p tonic-health -p tonic-prost -p tonic-reflection -p tonic-build -p tonic-prost-build -p pulldown-cmark -p crypto-bigint` then `sfw cargo check --workspace --lib --bins --tests --exclude rperf`.
Expected: tonic 0.14.8 brings zstd 0.14.3; check exits 0. If a tonic sibling refuses to move together, pin it with `--precise 0.14.8` and record why.

- [ ] **Step 3: Bump the probe lock**

Run: `cd rust/rdp-connector-probe && sfw cargo update -p crypto-bigint && sfw cargo check`
Expected: crypto-bigint 0.7.10 (0.7.3 to 0.7.8 are yanked); check exits 0.

- [ ] **Step 4: Re-run both audits**

Run the Step 1 command, and from `rust/rdp-connector-probe`: `sfw cargo audit --db /tmp/rustsec --no-fetch --deny warnings --ignore RUSTSEC-2023-0071 --ignore RUSTSEC-2023-0089`.
Expected: both exit 0.

- [ ] **Step 5: Sync the Bazel mirror and build**

Run: `bazel run //third_party/crate_mirror:sync && bazel build --config=remote //rust/...` (the probe is under `//rust/...`).
Expected: exit 0. `Cargo.toml:247-248` annotates `zstd-sys` with `deps = ["zstd"]`; a failure there names the BCR C library, not the Rust crate.

- [ ] **Step 6: Run the Rust tests**

Run: `sfw cargo test --workspace --exclude rperf` and `bazel test --config=remote //rust/...`
Expected: PASS. The PR itself runs both audits because `rust-checks.yml` paths include `Cargo.lock`.

- [ ] **Step 7: Commit**

```bash
git add Cargo.lock rust/rdp-connector-probe/Cargo.lock third_party/crate_mirror MODULE.bazel.lock
git commit -m "fix(rust): move tonic to 0.14.8 and clear the zstd, pulldown-cmark and crypto-bigint advisories"
```

---

### Task 3: Pass the repository to the release package publisher

**Files:**
- Modify: `.github/workflows/release.yml:937-939` (the `args` array; insert after the `--commit` line at 939)
- Modify: `scripts/test-release-publish-contracts.sh` (`required_workflow_fragments` at `:366-383`)
- Modify: `docs/fork-ci.md:39-67` ("Fork identity in code", one sentence)

**Interfaces:**
- Consumes: `build/release/publish_packages.go:217` `repoFlag := flag.String("repo", "carverauto/serviceradar", ...)`, validated at `:264-266` as `owner/repo`; `GITHUB_REPOSITORY` is always set in Actions and names the repository running the workflow.
- Produces: `args+=("--repo" "${GITHUB_REPOSITORY}")`, matching how lines 175 and 498 pass `--repository "${GITHUB_REPOSITORY}"` to other tools. No Go change: `parsePublishConfig` uses the global `flag` package and has no test.

- [ ] **Step 1: Write the failing contract**

Add the fragment `args+=("--repo" "${GITHUB_REPOSITORY}")` to `required_workflow_fragments`.
Run: `bash scripts/test-release-publish-contracts.sh`
Expected: FAIL naming the missing fragment.

- [ ] **Step 2: Add the argument and the doc sentence**

Insert the line; in `docs/fork-ci.md` "Fork identity in code" add that `release.yml` passes `--repo` from `GITHUB_REPOSITORY` because the binary's default names upstream.

- [ ] **Step 3: Run the fork CI checks**

Run: `scripts/ci/check-fork-ci.sh && bash scripts/test-release-publish-contracts.sh`
Expected: both exit 0.

- [ ] **Step 4: Record the proof point for the first real release**

In the PR body: on the first release, the publish step log must contain `Created release <tag> for jrmatherly/serviceradar` (`publish_packages.go:346`). No dispatch now; see Global constraints.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml scripts/test-release-publish-contracts.sh docs/fork-ci.md
git commit -m "fix(release): publish packages to the repository running the workflow"
```

---

### Task 4: Make the release script pass while the chart package does not exist yet

**Files:**
- Modify: `scripts/check-oci-chart-version-available.sh` (argument parsing at `:6-9` accepts exactly one argument today; status handling at `:31-45`)
- Modify: `scripts/cut-release.sh:194` (pass the new flag after `"$version"`, on dry and real runs alike; the check runs unconditionally before the dry-run branch at `:196`, so a real cut is blocked today too)
- Modify: `scripts/test-release-publish-contracts.sh` (fake Helm runner modes at `:252-279`; cut-release static contract at `:411-413` indexes the exact call string)
- Modify: `docs/RELEASE_PUBLISHING.md:57-58` (the dry run does contact the remote: a `git ls-remote` tag check and a Helm chart probe)

**Interfaces:**
- Consumes: `release.yml:826,855-873`, which logs in with `CHART_OCI_TOKEN` and maps status 0 to "free, push", 1 to "published, skip", other to "fail".
- Produces: a second positional argument `--anonymous-ok` (after `"$version"`, so the contract's indexed string stays intact) under which an anonymous `403 ... denied` from `ghcr.io/token` counts as "no such package". Without the flag, 403 stays exit 2: status 0 leads straight to a push and GHCR tags are mutable, so an authenticated probe that cannot read must not pass. If Step 2 shows the authenticated probe also returns 403 for a missing package, the script tells absent from denied by `gh api /users/jrmatherly/packages/container/charts%2Fserviceradar` returning 404; otherwise the first release carries a documented one-time step.

- [ ] **Step 1: Reproduce**

Run: `scripts/cut-release.sh --version 1.4.98 --dry-run --skip-changelog-check; echo "exit=$?"`
Expected: `exit=2` and stderr `Unable to verify OCI Helm chart occupancy ... response status code 403: denied`.

- [ ] **Step 2: Record what an authenticated probe of a missing package returns, without touching the user's Helm config**

Run: `gh auth refresh -s read:packages; export HELM_REGISTRY_CONFIG="$(mktemp -d)/config.json"; gh auth token | helm registry login ghcr.io -u jrmatherly --password-stdin && helm show chart oci://ghcr.io/jrmatherly/charts/serviceradar --version 1.4.98; echo "exit=$?"`
Expected: a status line pasted into the PR body. `404` or `name unknown` means the regex at line 42 gains `name unknown` and only the anonymous case changes.

- [ ] **Step 3: Write the failing contract cases**

Add a `denied` mode to the fake runner whose stderr is the GHCR 403 text. Two cases: `denied` with `--anonymous-ok` exits 0 and prints `is available` (the script's success text at `:43`); `denied` without the flag exits non-zero and prints `Unable to verify OCI Helm chart occupancy`, following the `unavailable` pattern at `:311-322`.
Run: `bash scripts/test-release-publish-contracts.sh`
Expected: FAIL on the new cases.

- [ ] **Step 4: Implement and re-run**

Run: `bash scripts/test-release-publish-contracts.sh && scripts/cut-release.sh --version 1.4.98 --dry-run --skip-changelog-check; echo "exit=$?"`
Expected: contracts PASS; `exit=0`. The `unavailable` mode (`dial tcp`) must still exit non-zero.

- [ ] **Step 5: Fix the doc sentence**

`docs/RELEASE_PUBLISHING.md:57-58` says the dry run does not contact the remote; replace with the two remote checks it performs.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-oci-chart-version-available.sh scripts/cut-release.sh scripts/test-release-publish-contracts.sh docs/RELEASE_PUBLISHING.md
git commit -m "fix(release): treat a missing chart package as available on an anonymous probe"
```

---

### Task 5: Move Go to 1.26.10 and add a scheduled govulncheck

**Files:**
- Modify: `go.mod:3` (`go 1.26.10`), `go.mod:47` and `go.sum` (`golang.org/x/net` v0.60.0), `.tool-versions:3`, `docker/rpm/Dockerfile.rpm.simple:16`, `.serena/memories/go/core.md:3`, `.serena/memories/tech_stack.md:4`
- Modify: `MODULE.bazel.lock` (new `go_sdk` index entry; `go_sdk.from_file` at `MODULE.bazel:685-688` follows `go.mod`; the lock has 40 `1.26.3` hits today and none for `1.26.10`)
- Create: `.github/workflows/govulncheck.yml`
- Modify: `docs/fork-ci.md:130-160` (Workflows table row `govulncheck.yml | schedule, dispatch | govulncheck | kept`)

**Interfaces:**
- Consumes: `.github/workflows/golangci-lint.yml` as the pattern: SHA-pinned `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` and `actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e` (`:41,52`), `go-version-file: go.mod`, the `go mod download` retry loop, `permissions: contents: read`. The job name `lint` is a required check in ruleset 25662015; the new workflow's job is `govulncheck` and runs on a weekly cron plus dispatch, like `rust-checks.yml` (`17 5 * * 1`), so a daily database change does not block unrelated PRs.
- Produces: `govulncheck ./...` exit 0 at the repo root under Go 1.26.10.

- [ ] **Step 1: Reproduce**

Run: `govulncheck ./...; echo "exit=$?"`
Expected: `exit=3`, "Your code is affected by 25 vulnerabilities from the Go standard library"; GO-2026-6809 (crypto/x509) is the one fixed only in 1.26.10; x/net GO-2026-6617 is reachable and fixed in v0.60.0.

- [ ] **Step 2: Bump the toolchain and x/net**

Edit the pins. Run: `go get golang.org/x/net@v0.60.0 && go mod tidy` (not `@latest`, which is v0.62.0 and drags sibling modules), then `mise install golang`.
Expected: `go version` prints go1.26.10; `go.sum` changes name x/net and nothing beyond its own requirements.

- [ ] **Step 3: Refresh the Bazel lock**

Run: `bazel mod deps --lockfile_mode=update && grep -c '1\.26\.10' MODULE.bazel.lock && grep -c '1\.26\.3' MODULE.bazel.lock`
Expected: the first count above 0, the second 0. Run `bazel mod tidy` if the go_deps `use_repo` list changed. Release workflows run with `--lockfile_mode=error` and fail on a stale lock (`docs/RELEASE_PUBLISHING.md:37-45`).

- [ ] **Step 4: Prove the vulnerabilities are gone and the build holds**

Run: `govulncheck ./...; echo "exit=$?"` then `go build ./... && go test ./go/...` and `bazel build --config=remote //go/... //:images`.
Expected: `exit=0`; builds and tests pass. `//:images` proves the SDK switch reaches the published images.

- [ ] **Step 5: Write the scheduled workflow and classify it**

`govulncheck.yml` per the Interfaces block, with `go install golang.org/x/vuln/cmd/govulncheck@v1.9.0` and `govulncheck ./...`. Add the `docs/fork-ci.md` table row.
Run: `scripts/ci/check-fork-ci.sh`
Expected: exit 0 (actionlint accepts the file). Dispatch once after merge: `gh workflow run govulncheck.yml --ref staging`, expected green.

- [ ] **Step 6: Commit**

```bash
git add go.mod go.sum .tool-versions docker/rpm/Dockerfile.rpm.simple .serena/memories MODULE.bazel.lock .github/workflows/govulncheck.yml docs/fork-ci.md
git commit -m "chore(go): move to go 1.26.10 and add a scheduled govulncheck"
```

## Appendix A. Alternatives rejected

- Ignoring the bandit, ash and jose advisories in `.deps_audit_ignore`. Every one has a released fix, so the ignore list is for esaml only, where no fix exists.
- Pinning tonic at 0.14.6 and ignoring the zstd advisories. zstd is a runtime decompressor on the gRPC path of every addon; the fix is one minor release away.
- Reading `GITHUB_REPOSITORY` inside `publish_packages.go`. The workflow already passes the repository explicitly to two other tools, and a Go change would need a test harness the file does not have.
- A `release.yml` dry-run dispatch to prove Task 3. The dispatch pushes real images and a real chart; the contract test is the proof.
- Accepting 403 as "absent" on the authenticated CI probe. That fails open onto a mutable tag.
- Making govulncheck a PR gate. The database changes daily and would block unrelated PRs; the weekly cron matches the Rust audit.

## Appendix B. Risks

- Task 1 moves ash three minor versions in the core; Ash changes query generation between minors, which is why Step 5 runs the DB-backed core suite and the unit target, not only the audit.
- Task 2 regenerates the crate mirror (about 1 GB download) and may touch `MODULE.bazel.lock`; review that diff for anything beyond the named crates.
- Task 5 changes the Go SDK inside every published Go image; it needs a publish after merge, which is the owner's dispatch.
