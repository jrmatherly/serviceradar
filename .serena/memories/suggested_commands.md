# Suggested commands (run from repo root; `make help` lists all)

- Hooks: `make hooks-setup` (core.hooksPath=.githooks + pre-commit).
- Build: `make build` (OCI via Bazel remote), `make build-workspace`, `make build-web-ng`, `make build-binaries` (local Go+Rust).
- Test: `make test` (Bazel unit tests like CI), `make test-toolchains`, `make check` (pre-push gate, remote cache).
- DB: `mix serviceradar.db.migrate` (NOT `mix ecto.migrate`; `--no-baseline` for full replay).
- Proto: `make generate-proto`, `make generate-proto-elixir`, `make verify-proto-elixir`, `make proto-lint`, `make proto-breaking`.
- Rust deps: `make update-rust-deps REPIN=workspace` or `scripts/update-rust-bazel-deps.sh`.
- Compose: `make compose-up`, `make compose-upgrade`. Demo: `make demo-staging-web` / `demo-staging-core`.
- Docs: `make docs-start|docs-build`.
- Release (user runs): `scripts/cut-release.sh` after CHANGELOG + VERSION update.
- Elixir app local run: see `docs/agent-runbooks.md` ("Local Development with Docker CNPG", "Web-NG Dashboard Visual Testing Loop"); from `elixir/web-ng`: `mix phx.server`.
- Git push: always `git push origin <local>:refs/heads/<branch>`.

## Darwin notes
- macOS BSD tools: `sed -i ''`, no GNU `readlink -f`/`xargs -r`; Makefile has `HOST_OS=Darwin` branches (SwiftLint runs only on Darwin; `push-web-ng` Linux/CI only, macOS uses `make push_all`).
- `make agent-build-darwin`, `agent-package-macos` for the mac agent.
- Do not run docker commands without user request.
