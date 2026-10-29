# Go (`go/`)

- Module root `go.mod` at repo root (`github.com/carverauto/serviceradar`, Go 1.26.10). Binaries in `go/cmd/` (agent, agent-updater, cli, data-services, faker, k8s-inventory, wasm-plugins, terraform-provider-serviceradar, ...); libs in `go/pkg/` (agent, mapper, edgeonboarding, db, grpc, models, ...).
- Lint config `.golangci.yml`; `make lint-go`. Go stdlib `plugin` is forbidden in agent/add-on builds (`make check_addon_no_stdlib_plugin`).
- Native add-ons: size/deadcode gates (`make check_addon_binary_size_bazel`, `check_addon_deadcode_elimination`).
- Agents must not write metrics directly to DB; publish to JetStream.
