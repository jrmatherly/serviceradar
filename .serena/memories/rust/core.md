# Rust (`rust/`)

- Single root Cargo workspace (`Cargo.toml`); members under `rust/*`, `config/*/rust`, `integration_tests/srql*`, and NIF crates in `elixir/*/native`.
- Crates include srql (Diesel + CNPG), anomaly-core (single source of truth for anomaly primitives, DeepCausality), anomaly-addon, flow-collector, trapd, flowgger, netprobe, otel, log-collector, kvutil, topology-atlas.
- Bazel consumes Rust via vendored crate mirror `//third_party/crate_mirror`; after hand-editing root `Cargo.toml` run `bazel run //third_party/crate_mirror:sync`; full bump via `make update-rust-deps REPIN=workspace`.
- Lint: `./scripts/lint-rust.sh` (clippy CI gate). Prefix cargo dep fetches with `sfw`.
- Do not extend legacy `causal_reasoner_nif`; anomaly detection moved to edge.
