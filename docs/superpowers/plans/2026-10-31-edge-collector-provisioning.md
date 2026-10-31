# Edge Collector Provisioning End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An edge collector package of every type (flowgger, trapd, otel, netflow, sflow, falcosidekick) provisions on Compose, gets a bundle its binary accepts, and publishes into the right central stream, either direct to the hub or through an edge leaf server.

**Architecture:** Core mints collector-type NATS users through datasvc (`ServiceRadar.NATS.AccountClient` -> datasvc gRPC `GenerateUserCredentials` -> `go/pkg/nats/accounts`). Edge credentials hold only their data subjects and make no stream API call; the trusted stream owner (otel log-collector, or core's EventWriter) creates each stream and captures the subjects. This plan wires the missing account configuration, brings the stale netflow/sflow and falcosidekick bundles in line with their binaries, and gives the leaf server local authorization matching hub-side scoping.

**Tech Stack:** Elixir/Ash (serviceradar_core, web-ng), Go (`go/pkg/cli`, `go/pkg/nats/accounts`), Rust (`rust/flow-collector`), NATS 2.14 (JWT operator mode in Compose, static mTLS users in Helm and on leaf servers).

**Spec:** this plan's Findings section, from the 2026-10-31 session on branch `fix/nats-platform-account-subjects` (commits 540d60f92c..ca7eb0505a). No separate design doc exists.

## Findings (the spec)

1. `ProvisionCollectorWorker` and `NatsLeafCredentials` read `Application.get_env(:serviceradar, :nats_account_name | :nats_account_seed)`. Nothing sets them (checked: `grep -rn 'nats_account_seed' elixir/*/config docker-compose*.yml helm/` is empty), so every package fails with `:nats_not_configured`.
2. `go/pkg/cli/nats_bootstrap.go` `writePlatformAccountFiles` writes `platform.creds` and the account JWT but never the platform **account seed**, so core has nothing to mint with.
3. `collector_bundle_generator.ex` `generate_netflow_config/2` and `generate_sflow_config/2` write `{listen_addr, stream_name: "events", subject: "events.netflow" | "flows.raw.sflow"}`. The current `rust/flow-collector` config needs `listeners: [{protocol, listen_addr, subject}]` and `stream_name: "flows"` (see `docker/compose/flow-collector.docker.json`).
4. flow-collector acts as owner of the `flows` stream (`ensure_owned_stream`, `ensure_flows_stream`, `detach_subjects_from_stream` in `rust/flow-collector/src/publisher.rs` call STREAM.CREATE/UPDATE). Edge credentials hold no stream API, by design.
5. falcosidekick bundle default `subject_template` is `falco.<priority>.<rule>`; the EventWriter `events` stream captures only `falco.logs` (`event_writer/config.ex` FALCO entry; `docs/docs/falco.md` says falcosidekick publishes `falco.logs`).
6. Leaf servers (`nats_leaf_config_generator.ex`) run in static mode with `verify_and_map`; JWT permissions are ignored there. With no direct identities there is no `authorization` block at all (every local client unrestricted); with one, `default_permissions` grants `$JS.API.>`.
7. nats-server parses `allow: []` as **unrestricted** in both directions (verified on 2.14.0). Use `deny: [">"]` to grant nothing.

## Global Constraints

- Greenfield: no installs or data; no migration paths.
- Never write a captured value into fixtures; use `host01.example.com`, `192.0.2.0/24`, invented IDs (CLAUDE.md).
- Collector credentials must never hold STREAM.CREATE/UPDATE/DELETE/PURGE or `$JS.API.>` (validator: `allowedSystemSubject` in `go/pkg/nats/accounts/account_manager.go`).
- Every negative ACL test asserts a **timeout** (`deniedJS` in `go/pkg/cli/nats_bootstrap_platform_subjects_integration_test.go`), and is proven to fail when the grant is widened.
- Push only `git push origin <local>:refs/heads/<branch>`; never to staging.

## Review Focus

1. An edge collector starting before the owner has created its stream: it must wait or retry, not crash or create. Edge bundles make no lookup (`stream_owner = false`, and trapd with `nats_domain` set), so a missing stream shows as no responders on the publish. flow-collector, flowgger and otel's exporter retry it; trapd logs and drops the trap, because a retry would block its receive loop.
2. A collector whose bundle subject is not captured by the owner's stream: publishes are acked by nobody; the bundle test must assert every bundle subject is covered by a stream the owner creates.
3. Account seed exposure: whoever reads the seed can mint any user in the platform account. Core cannot read it and datasvc is the only service given it by name. Who can read it (file mode, mounts) must be asserted.
4. A leaf server with zero direct identities: must still deny everything except the collectors' scoped subjects (no missing `authorization` block).
5. Revoking a package: the hub must refuse its credential. `NatsCredential` `:revoke` calls datasvc `RevokeUsers` first and fails if the hub was not updated; `scripts/compose-check-nats-revocation.sh` proves it on a running stack, including across the NATS init containers. A rotated platform seed changes the account key, which already invalidates every credential it signed. Behind an edge leaf the static user keeps working until the site's bundle is re-installed, because a leaf maps the certificate and ignores the credential.

---

### Task 1: Give core the platform account to mint from (decision + wiring)

**Files:**
- Modify: `go/pkg/cli/nats_bootstrap.go` (`writePlatformAccountFiles`, `natsBootstrapPaths`)
- Modify: `docker/compose/init-nats-creds.sh` (`required_artifacts`)
- Modify: `docker-compose.yml` (core-elx env + mount)
- Modify: core runtime config that reads env (`elixir/serviceradar_core_elx/config/runtime.exs` or wherever `:serviceradar` env is set; find with `grep -rn 'config :serviceradar,' elixir/*/config/runtime.exs`)
- Test: `go/pkg/cli/nats_bootstrap_acl_test.go`

**Decision (owner):** datasvc holds the platform account seed. Core never sees it and asks datasvc to mint by account name: `GenerateUserCredentialsRequest` drops `account_seed`, and datasvc signs with `platform_account_seed_file` from its operator config. datasvc already mounts `operator.seed`, so it gains no power, and a compromised core gets only credentials that pass the datasvc validator rather than the key that signs any user in the account.

- [x] Step 1: Write failing test `TestBootstrapWritesPlatformAccountSeedFile` asserting `platform_account.seed` exists with mode `0600` after `bootstrapLocalCreds`, starts with `SA`, and that `platform.creds` and the seed belong to the same account public key.
- [x] Step 2: Run `go test ./go/pkg/cli/ -run TestBootstrapWritesPlatformAccountSeedFile`; expect FAIL (file missing).
- [x] Step 3: Write `platformResult.AccountSeed` to `<outputDir>/platform_account.seed` (0600) in `writePlatformAccountFiles`; add to `required_artifacts`; mount it **only** into the service the decision names (core-elx or datasvc) as a volume subpath, like the collectors' mounts.
- [x] Step 4: Set `:nats_account_name` = `platform` in runtime config. Per the decision above, core gets no seed. The existing `provision_collector_worker_test.exs` runs only in the CI DB lane.
- [x] Step 5: Compose check: mint trapd credentials over the datasvc RPC the worker calls, not through the package API. Commit.

### Task 2: Netflow/sflow bundles match the current flow-collector

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/edge/collector_bundle_generator.ex` (`generate_netflow_config/2`, `generate_sflow_config/2`)
- Test: `elixir/web-ng/test/serviceradar_web_ng/edge/collector_bundle_generator_test.exs`

- [x] Step 1: Failing test `netflow bundle uses flow-collector listeners`: decoded JSON has `"stream_name" => "flows"` and `"listeners" => [%{"protocol" => "netflow", "listen_addr" => "0.0.0.0:2055", "subject" => "flows.raw.netflow"}]`; sflow likewise with `6343`/`flows.raw.sflow`; no top-level `subject` key.
- [x] Step 2: Run it; expect FAIL.
- [x] Step 3: Emit the flow-collector schema (copy key names from `rust/flow-collector/src/config.rs` `Config`/`ListenerConfig`); keep `config_overrides["listen_addr"]` mapping to the listener's `listen_addr`.
- [x] Step 4: Add a Rust test in `rust/flow-collector` that parses a fixture produced by the generator (store the fixture under `rust/flow-collector/testdata/edge-netflow.json`, invented values).
- [x] Step 5: Run both; commit.

### Task 3: flow-collector non-owner mode for edge use

**Files:**
- Modify: `rust/flow-collector/src/config.rs` (new `stream_owner: bool`, default `true`)
- Modify: `rust/flow-collector/src/publisher.rs` (`ensure_owned_stream` path)
- Modify: `collector_bundle_generator.ex` (set `"stream_owner" => false` for edge bundles)
- Test: `rust/flow-collector/src/publisher.rs` tests

- [x] Step 1: Failing test `non_owner_never_creates_or_updates_streams`: with `stream_owner = false` the publisher sends no stream request.
- [x] Step 2: Implement: when `!stream_owner`, skip create/update/detach and make no `$JS.API.STREAM.*` request at all. Waiting on 10059 cannot work behind a leaf: measured from a leaf client, `$JS.API.STREAM.INFO.<stream>` is answered by the leaf's own JetStream with 10059 while a JetStream publish lands on the hub stream, so a collector gating on the lookup waits forever (commit 61e2606301). A missing stream shows as no responders on the publish and the batch retries. The non-owner assumes the owners' 120s duplicate window, since it cannot read it.
- [x] Step 3: Confirm core's EventWriter creates `flows` with `flows.raw.>` captured (`event_writer/config.ex`); if not, add it there with a test.
- [x] Step 4: `cargo fmt`, `cargo clippy -D warnings`, Bazel `//rust/flow-collector/...`; commit.

### Task 4: Falcosidekick subject alignment

**Files:**
- Modify: `collector_bundle_generator.ex` (`generate_falcosidekick_config/2` default `subject_template`)
- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/workers/provision_collector_worker.ex` (`collector_permissions(:falcosidekick)`) and its test
- Test: bundle generator test

- [x] Step 1: Failing test: default bundle `subject_template` is `"falco.logs"` and `collector_permissions(:falcosidekick).publish_allow == ["falco.logs"]`.
- [x] Step 2: Implement both; update `collector_permissions_test.exs` expectation.
- [x] Step 3: Run the core edge unit shard (`bazel test --config=remote -c opt //elixir/serviceradar_core:unit_tests_serviceradar_edge`); commit.

### Task 5: Leaf server local authorization for collectors

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/nats_leaf_config_generator.ex` (`render_direct_leaf_authorization/1`, `generate_config/3`)
- Test: `elixir/serviceradar_core/test/serviceradar/edge/nats_leaf_config_generator_test.exs`

- [x] Step 1: Failing tests: (a) with zero direct identities the config still contains an `authorization` block; (b) `default_permissions` contains no `$JS.API.>` and no `allow: []`; (c) collector users get exactly `ProvisionCollectorWorker.collector_permissions/1` subjects (single source).
- [x] Step 2: Render per-collector users from the edge site's assigned packages (CN `<component>.<partition>.serviceradar`), and `default_permissions: { publish: { deny: [">"] }, subscribe: { deny: [">"] } }`.
- [x] Step 3: Prove it parses and enforces: `go/pkg/cli/nats_leaf_authorization_integration_test.go` loads generator output (fixtures pinned by `nats_leaf_config_generator_test.exs`) into an embedded leaf linked to an embedded hub. It runs nats-server v2.15.0 from `go.mod`, not 2.14.
- [x] Step 4: Commit.
