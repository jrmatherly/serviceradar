# ServiceRadar (fork jrmatherly/serviceradar of carverauto/serviceradar)

Monitoring platform: Elixir/Ash/Phoenix control plane + Go agents/services + Rust collectors/SRQL. Default branch `staging`. Instructions: root `AGENTS.md`, `CLAUDE.md`, `openspec/AGENTS.md` (proposals/specs/plans), `elixir/web-ng/AGENTS.md`, `docs/agent-runbooks.md`.

## Source map
- `elixir/` serviceradar_core (Ash domains), serviceradar_core_elx, serviceradar_agent_gateway, serviceradar_srql, web-ng (Phoenix UI/API), datasvc, palisade. See `mem:elixir/core`.
- `go/cmd/` binaries (agent, cli, data-services, faker, ...), `go/pkg/` shared libs. See `mem:go/core`.
- `rust/` crates (srql, anomaly-core, flow-collector, trapd, ...), root `Cargo.toml` workspace incl. NIFs under `elixir/*/native`. See `mem:rust/core`.
- `docker/` (compose Dockerfiles, images), `helm/serviceradar/` (supported k8s install), `k8s/`, `terraform/`. See `mem:docker/core`.
- `proto/` protobuf (Go/Rust/Elixir bindings generated), `openspec/` change proposals, `docs/` (runbooks at root, `docs/docs/` = published Docusaurus), `scripts/`, `addons/`, `integrations/`, `swift/`, `js/`.

## Hard invariants (full text in AGENTS.md / CLAUDE.md)
- Fixtures/docs/tests are synthetic; never commit data captured from a live system (hosts, IPs, MACs, serials, names, coords...). Regenerate, do not search-replace.
- GitHub (`gh`) is the collaboration host; Forgejo retired for this repo.
- Never push to `staging`; push with explicit refspec `git push origin <local>:refs/heads/<branch>`; worktrees via `git worktree add --no-track -b <name> origin/staging`.
- Releases via `scripts/cut-release.sh` (user runs).
- All metrics/telemetry go through NATS JetStream -> `event_writer`; never write metrics directly to DB. StarRocks on => telemetry only there; off => CNPG. Flows are StarRocks-only.
- Device/integration credentials live in CNPG `platform.network_credential_secrets` (unified credential model), not k8s/Vault/Helm/env secrets.
- Single-deployment: no multitenancy features or bypass modes.
- Anomaly/causal logic: use `serviceradar-anomaly-core` (DeepCausality); do not hand-roll detectors.
- External artifact downloads via `ServiceRadar.HTTP.EgressClient`.
- Verification must be able to fail; gate on artefacts, not job status. Close bad-data creation paths before deleting.
- LiveView: no DB queries in disconnected mount; streams for >100 items.
- Tests that commit data must delete it (prefer boxed sandbox).
- Load `test-audit` skill before writing/changing tests.

See `mem:tech_stack`, `mem:suggested_commands`, `mem:conventions`, `mem:task_completion`.
