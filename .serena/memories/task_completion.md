# Task completion checklist

Compile, run applicable tests, read the output, report every check not run.

- Elixir (per project under `elixir/<p>`): `mix precommit` (compile --warnings-as-errors, deps.unlock --unused, format, test); lint-only: `mix precommit_lint`; fast: `mix precommit_fast`. Repo-wide: `make format-elixir`, `make lint-elixir` (uses `scripts/elixir_quality.sh`, `--phoenix` for web-ng), `make lint-elixir-dialyzer` on demand.
- Go: `gofmt` on changed files, `make lint-go`, `make tidy`; tests via Bazel (`bazel test <target>`) or `make test`.
- Rust: `cargo fmt`, `./scripts/lint-rust.sh` (`make format`), tests via Bazel/cargo for touched crate.
- Whole: `make lint`, `make test`, pre-push `make check`.
- Proto changes: `make proto-lint proto-breaking verify-proto-elixir`.
- Add-ons: `make addon_build_gates`.
- Tests that commit data must clean up in `on_exit`; never loosen assertions for leaked rows.
- Load `test-audit` skill before test changes.
- Verify with a check that can fail (query artefacts written after the deploy, copy real log lines before writing patterns).
