# NATS Hardening Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the smaller least-privilege and robustness gaps left after branch `fix/nats-platform-account-subjects`, and give Helm and Compose one source of truth for NATS permissions.

**Architecture:** Compose issues JWT credentials from the registry `serviceIdentities()` in `go/pkg/cli/nats_bootstrap.go` (core, flow-collector, datasvc, log-collector, trapd, bmp-collector) plus `platformPermissions()`. Helm declares static mTLS users in `helm/serviceradar/templates/nats.yaml`. Both are hand-maintained today.

**Tech Stack:** Go, Helm (helm-unittest v1.2.1 plugin installed), Rust (trapd), NATS 2.14.

**Spec:** this plan's Findings section (2026-10-31 session, commits 540d60f92c..ca7eb0505a; two independent code reviews and three automated security reviews).

## Findings (the spec)

1. Helm and Go permission lists are duplicated by hand (datasvc, core, collectors); drift already happened once (a stale `nats.conf` copy, deleted in 6f4ec5f02e).
2. `docker/compose/init-nats-creds.sh` `required_artifacts` must list every `serviceIdentities()` user by hand.
3. Datasvc bucket names are hardcoded (`datasvcKVBucket`, `datasvcObjectBucket` in Go; Helm uses `.Values.kv.bucket` / `$datasvc.objectBucket`), but datasvc config allows renaming.
4. `allowedSystemSubject` approves `$O.` and `$KV.` prefixes for **every** service credential minted through datasvc gRPC `GenerateUserCredentials`.
5. JWT custom permissions with an empty allow list keep type defaults (safe today), but nats-server treats an empty allow list as unrestricted; nothing guards a future caller.
6. trapd reports gRPC health SERVING while waiting for its stream (`rust/trapd/src/main.rs`).
7. Helm flowgger `nats_connect_attempts = 10` (`log-collector.yaml:55`, `log-collector-tcp.yaml:51`) gives up after about 2 minutes if the `events` owner is late.
8. Helm `serviceradar-tools` keeps publish/subscribe `>` (deliberate toolbox; most privileged NATS cert). web-ng, core and datasvc-adjacent Helm users still hold `$JS.API.>` (core deliberately, with datasvc-stream denies); web-ng not audited.
9. Branch `fix/nats-platform-account-subjects` (8 commits) has no PR yet.

## Global Constraints

- Greenfield: no installs or data; no migration paths.
- Every negative ACL test asserts a timeout and is proven to fail when widened.
- `.github/`, `scripts/ci/` changes need `scripts/ci/check-fork-ci.sh`.
- Push only `git push origin <local>:refs/heads/<branch>`; open PRs with `gh -R jrmatherly/serviceradar`.

## Review Focus

1. A bucket renamed in datasvc config: datasvc must still reach its streams (generated grants follow the config).
2. A new identity added to the registry: Compose init and Helm must fail a test until updated.
3. A datasvc gRPC caller requesting `$KV.>` for an arbitrary service credential: must be rejected unless it names the datasvc bucket.
4. An empty custom allow list passed to `GenerateUserCredentials`: must be rejected, not silently unrestricted.
5. trapd waiting for a stream that never appears: health must report NOT_SERVING.

---

### Task 1: Open the PR for the current branch

- [ ] Step 1: `git push origin fix/nats-platform-account-subjects:refs/heads/fix/nats-platform-account-subjects`; confirm the push line says `-> fix/nats-platform-account-subjects`.
- [ ] Step 2: `gh pr create -R jrmatherly/serviceradar --base staging` with a body summarizing the 8 commits, the verification table, and "test-audit: not available" (AGENTS.md); do not name any affected party.
- [ ] Step 3: Watch BazelCI, lint and gitleaks; merge with `gh pr merge N --merge` once green.

### Task 2: One source of truth for identity permissions

**Files:**
- Create: `go/pkg/cli/nats_identities_manifest.go` (`func IdentityManifest() []IdentitySpec`, `IdentitySpec{User string; Publish, Subscribe []string}`)
- Modify: `go/pkg/cli/nats_bootstrap.go` (build `serviceIdentities()` from the manifest)
- Create: a CLI subcommand `serviceradar-cli nats-identities --format helm-json` printing the manifest
- Modify: `helm/serviceradar/templates/nats.yaml` to read the generated JSON from `helm/serviceradar/files/nats-identities.json` (generated, committed)
- Test: `go/pkg/cli/nats_identities_manifest_test.go` (`TestHelmIdentitiesFileMatchesManifest`: regenerate and diff the committed file); helm test asserting each Helm user equals the file

- [ ] Step 1: Failing test `TestHelmIdentitiesFileMatchesManifest`.
- [ ] Step 2: Implement manifest + generator; regenerate file; render Helm users from it with `fromJson (.Files.Get ...)`.
- [ ] Step 3: `helm unittest helm/serviceradar` (all 94 suites) and `go test ./go/pkg/cli/`; commit.

### Task 3: Init script derives required artifacts from the bootstrap

**Files:** `docker/compose/init-nats-creds.sh`, `go/pkg/cli/nats_bootstrap.go` (JSON output already lists `<user>_creds_path`)

- [ ] Step 1: Add a bats or Go test that fails when a registry user is missing from `required_artifacts`.
- [ ] Step 2: Generate the list from `serviceradar-cli nats-bootstrap --list-artifacts` (new flag) instead of hand-listing; commit.

### Task 4: Bucket names follow datasvc config

**Files:** `go/pkg/cli/nats_bootstrap.go` (`datasvcKVBucket`, `datasvcObjectBucket`), Compose env

- [ ] Step 1: Failing test: with `SERVICERADAR_DATASVC_KV_BUCKET=synthetic-kv`, `datasvc.creds` grants `$KV.synthetic-kv.>` and `$JS.API.STREAM.INFO.KV_synthetic-kv`, and platform denies target `KV_synthetic-kv`.
- [ ] Step 2: Read bucket names from env with the current defaults; commit.

### Task 5: Narrow validator approvals for gRPC-minted credentials

**Files:** `go/pkg/nats/accounts/account_manager.go` (`allowedSystemSubject`), `go/pkg/nats/accounts/user_manager.go` (`validateUserPermissions`)

- [ ] Step 1: Failing tests: `$KV.>` and `$O.>` rejected for service credentials; `$KV.<bucket>.>` accepted only for a concrete bucket token; an empty non-nil `PublishAllow` or `SubscribeAllow` returns a new `ErrEmptyAllowList`.
- [ ] Step 2: Implement; confirm the bootstrap and datasvc tests still pass (`go test ./go/pkg/cli/ ./go/pkg/nats/accounts/ ./go/pkg/datasvc/`, Bazel for datasvc); commit.

### Task 6: trapd health reflects the stream wait

**Files:** `rust/trapd/src/main.rs` (health reporter, wait loop)

- [ ] Step 1: Failing test: while `ensure_stream` returns `StreamState::Missing`, the health status is `NOT_SERVING`; after `Ready`, `SERVING`.
- [ ] Step 2: Set status through the existing `health_reporter`; `cargo clippy -D warnings`; commit.

### Task 7: Helm flowgger retries until the owner exists

**Files:** `helm/serviceradar/templates/log-collector.yaml:55`, `log-collector-tcp.yaml:51`, helm test

- [ ] Step 1: Failing helm test: rendered flowgger config has `nats_connect_attempts = 0` (unbounded, matching Compose).
- [ ] Step 2: Change both templates; run `helm unittest`; commit.

### Task 8: Audit web-ng and tools NATS grants (decision)

- [ ] Step 1: Trace web-ng's NATS calls (`grep -rn 'Gnat\.\|JetStream\|ObjectStore' elixir/web-ng/lib`) and record its true subject/API set.
- [ ] Step 2: Owner decision: keep `serviceradar-tools` at `>` or restrict to read-only plus `$JS.API.STREAM.INFO.*`. Record it.
- [ ] Step 3: Narrow web-ng's Helm user to the traced set with a helm test; commit.
