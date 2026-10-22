# Elixir projects (`elixir/`)

- Projects: `serviceradar_core` (Ash resources/domains: Identity, Inventory, Infrastructure, Monitoring, Edge; has `native/` NIFs), `serviceradar_core_elx`, `serviceradar_agent_gateway`, `serviceradar_srql` (`native/srql_nif`), `web-ng` (Phoenix UI/API, `native/god_view_nif`), `datasvc`, `palisade`. Each has its own `.credo.exs`.
- Ash resources live in serviceradar_core, consumed by web-ng via `scope:` (`ServiceRadarWebNG.Accounts.Scope`). Dedicated-deployment model: schema isolation via CNPG search_path, no deployment ids in code.
- Read `elixir/web-ng/AGENTS.md` before touching web-ng (mandatory); `elixir/serviceradar_core/CLAUDE.md` exists too.
- web-ng mix aliases: `precommit`, `precommit_lint`, `precommit_fast`.
- Migrate DB with `mix serviceradar.db.migrate`. Baseline cannot be used on DBs with Timescale hypertables/AGE graphs.
- Analyzer contract: `scripts/elixir_quality.sh`; boundary compiler dev/test only.
