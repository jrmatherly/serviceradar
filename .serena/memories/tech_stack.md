# Tech stack

- Elixir 1.19.4 / Erlang 28.3 (`.tool-versions`); Phoenix 1.8 LiveView, Ash 3.x, Tailwind v4, Bun for web-ng assets, Req for HTTP.
- Go 1.26.3 (`go.mod`, module `github.com/carverauto/serviceradar`); golangci-lint pinned via `make get-golangcilint`.
- Rust: Cargo workspace (root `Cargo.toml`), Diesel + CNPG for SRQL, Rustler NIFs, DeepCausality-based `anomaly-core`.
- Build: Bazel (bzlmod `MODULE.bazel`, rules_go, rules_elixir, aspect_rules_js/ts), remote cache/exec configured in `.bazelrc`; Makefile wraps Bazel.
- Data: CNPG (Postgres + TimescaleDB, AGE graphs), NATS JetStream, optional StarRocks (telemetry warehouse), Dgraph.
- Deploy: Helm chart `helm/serviceradar/`, Docker Compose (`docker-compose.yml`, `docker-compose.dev.yml`), ArgoCD demo.
- Protobuf via Buf (`make proto-lint`, `generate-proto`, `generate-proto-elixir`).
- Docs: Docusaurus under `docs/docs/`.
- Dependency-fetching npm/pip/uv/cargo/bun commands: prefix with `sfw` (Socket Firewall); not for Go, Bazel, Hex/Mix.
- Swift (SwiftLint on Darwin) under `swift/`.
