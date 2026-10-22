# Deviations from upstream

A row per decided deviation. An upstream hunk that conflicts with a landed row
keeps ours; a `planned` row warns that the conflict is coming; an `open` row
means ask the owner before adopting the PR.

| Upstream | Ours | Status | Notes |
| --- | --- | --- | --- |
| `.github/`, `buildbuddy.yaml`, `build/rbe/BUILD`, `build/ci/*.py`, `scripts/ci/`, `docker/images/base_image_origins.txt`, image hosts in `MODULE.bazel` | fork-owned CI: hosted runners, BuildBuddy RBE, GHCR images and base-image mirrors, fork signing keys, publishing gated behind `PUBLISH_ENABLED` | landed 2026-10-22 (PR jrmatherly/serviceradar#4) | an upstream change to any of these paths is never cherry-picked: hand-port it per `docs/fork-ci.md`, then `scripts/ci/check-fork-ci.sh` must exit 0; new validation commands also go into `validation.md` |
| carverauto names: module `github.com/carverauto/serviceradar`, images `ghcr.io/carverauto/*`, product name | rebrand | planned | the mapper is to be adapted from ai-kb `scripts/rebrand/` (`map.tsv`, `apply.sh`, `check.sh`, `check-repo.sh`); until it exists the rebrand step in SKILL.md is a no-op |
| upstream `VERSION`, `CHANGELOG` and dependency-only bumps | tracked while identical, ours once diverged | landed 2026-10-21 | ADOPT such a PR while every file it touches shows `=`, `+`, or `<` with its predecessors adopted (the ordinary ADOPT rule). The first time one of those files shows `~`, that file is ours: SKIP the PR and take only the versions it names (`go get`, `mix deps.update`, `npm install pkg@x`, `cargo update -p`), never the hunk, then rerun that area's validation. Re-decide when the fork publishes its own artifacts or the rebrand lands. |
| Rust formatting: upstream has no rustfmt gate and carries unformatted workspace files | `cargo fmt --all` applied across the workspace, enforced by the Rustfmt job in `rust-checks.yml` | landed 2026-10-22 | a `.rs` file shows `~` once we reformatted it. Pick the upstream commit, resolve any conflict toward upstream's code, then rerun `cargo fmt --all` and amend; never hand-merge formatting |
| `.tool-versions` pins Erlang and Elixir only | adds `golang` matching `go.mod` | landed 2026-10-22 | keeps a newer system Go out of the repo, so `make lint-go` and Go tests run on the pinned toolchain; bump it with `go.mod` |

## Deleted or moved paths

An `x` marker means we removed the path, not always that the change is
irrelevant. Add a line here for every path we remove, with where the content
went or why it is gone.
