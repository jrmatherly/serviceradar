# Validation per area

Run, for each area an adopted batch touched, the commands below from the repo
root, and record the outcome per area in the decision log. Every target named
here exists in the `Makefile` or as a script (checked 2026-10-21); verify with
`grep -n '^<target>:' Makefile` before adding one.

Prerequisites, once per machine: `mise install` at the repo root (the toolchains
`.tool-versions` pins, Go included: a newer Homebrew Go breaks `make lint-go`
and Go tests that compare error text), `mix local.hex --force && mix
local.rebar --force`, `mix deps.get` in every project `ELIXIR_PROJECTS` names in
the `Makefile` (the format and lint gates walk all seven, so one unfetched
project fails the whole gate; `datasvc` was the one missed on 2026-10-22), and a
`.bazelrc.remote` for the Bazel rows. Write `.bazelrc.remote` with the BuildBuddy key read
from the terminal, so it stays out of shell history:
`read -rs BUILDBUDDY_ORG_API_KEY && export BUILDBUDDY_ORG_API_KEY && scripts/ci/configure-bazel-remote.sh; unset BUILDBUDDY_ORG_API_KEY`.
Under mise, `MIX_HOME` is `~/.local/share/mise/installs/elixir/<ver>/.mix`; the `Makefile`
reads that variable for `protoc-gen-elixir`, so export it (mise does) rather than assuming
`~/.mix`.

| Area | Commands |
| --- | --- |
| Elixir, any project under `elixir/` | `make format-elixir`, `make lint-elixir` |
| Elixir `web-ng` or `palisade` | additionally `cd elixir/<project> && mix precommit` (the only two `mix.exs` that define the alias) |
| Go | `gofmt -l <changed files>` (must print nothing), `make lint-go`, `make tidy` (expect `go fmt ./...` to realign 15 Go files that are misformatted on upstream `staging` and guarded by no gate; do not commit them with a batch, see `deviations.md` "Open") |
| Rust | `cargo fmt --all --check` (the CI Rustfmt gate), `make format` (`scripts/lint-rust.sh`, the CI clippy gate) |
| Protobuf | `make proto-lint proto-breaking verify-proto-elixir` (`verify-proto-elixir` finds `protoc-gen-elixir` under `$MIX_HOME/escripts`; a "protoc-gen-elixir: program not found or is not executable" error means `MIX_HOME` is unset in the shell) |
| Helm chart | `helm lint helm/serviceradar`, then the `helm template` step from `.github/workflows/helm-lint.yml` |
| Tests | the touched project's own runner: `mix test` in the Elixir project, `go test ./...` in the Go module, `cargo test -p <crate>` for Rust |
| Bazel-only Go tests | a `go_test` with `data` or `$(rlocationpath ...)` env reads Bazel-built files and fails under `go test` with `runfiles: no runfiles found`; run its target instead, `bazel test --config=remote //<pkg>:<target>` (for example `//build/wasm_plugins:plugin_runtime_test`, `//go/pkg/nats/chartacl:chartacl_test`). The same goes for tests that bind `127.0.0.2` and up, which macOS does not route (`//go/pkg/mapper:mapper_test`) |

Boundary warnings that a module "is not included in any boundary" after a
`mix deps.get` (or a compile that overlapped one) are stale build state, not
missing boundaries: `ServiceRadar`, `ServiceRadarWebNG` and
`ServiceRadarAgentGateway` claim their whole namespaces. Run `mix compile --force`
in the project and rerun the gate before changing any boundary.

`--config=remote` runs on the fork's BuildBuddy Cloud org once `.bazelrc.remote`
exists (checked 2026-10-22 on the three targets above). The full `make test`
sweep has not been run locally; `make check` (`--config=ci`) is CI's profile.
Report either as not run unless you ran it.
