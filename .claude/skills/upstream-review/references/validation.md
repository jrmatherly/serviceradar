# Validation per area

Run, for each area an adopted batch touched, the commands below from the repo
root, and record the outcome per area in the decision log. Every target named
here exists in the `Makefile` or as a script (checked 2026-10-21); verify with
`grep -n '^<target>:' Makefile` before adding one.

| Area | Commands |
| --- | --- |
| Elixir, any project under `elixir/` | `make format-elixir`, `make lint-elixir` |
| Elixir `web-ng` or `palisade` | additionally `cd elixir/<project> && mix precommit` (the only two `mix.exs` that define the alias) |
| Go | `gofmt -l <changed files>` (must print nothing), `make lint-go`, `make tidy` |
| Rust | `cargo fmt --check` in the touched crate, `make format` (`scripts/lint-rust.sh`, the CI clippy gate) |
| Protobuf | `make proto-lint proto-breaking verify-proto-elixir` |
| Helm chart | `helm lint helm/serviceradar`, then the `helm template` step from `.github/workflows/helm-lint.yml` |
| Tests | the touched project's own runner: `mix test` in the Elixir project, `go test ./...` in the Go module, `cargo test -p <crate>` for Rust |

Not runnable on the fork: `make check` (Bazel `--config=ci`, which `.bazelrc`
points at upstream's in-cluster remote cache) and `make test` (Bazel
`--config=remote`, upstream's BuildBuddy remote executor). Say so in the log
instead of reporting them as passed.

Upstream `.github/workflows/` changes are the source for new commands: port
them into this table and into our workflows by hand.
