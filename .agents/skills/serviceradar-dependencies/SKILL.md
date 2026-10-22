---
name: serviceradar-dependencies
description: The dependency rules ServiceRadar's Cargo and Bazel builds share, and the traps that pass `cargo check` and break Bazel. Use when fetching, installing, bumping or pinning JavaScript, Python, Rust, Cargo, Bazel crate, OpenSSL or pq dependencies, editing a `Cargo.toml`, or touching `third_party/crate_mirror`.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar Dependency Rules

The fetch-time rules shared with every agent are in [AGENTS.md](../../../AGENTS.md):
the Rust dep bump command (`make update-rust-deps REPIN=workspace`, under
"Per-Directory Agent Guides") and the Socket Firewall `sfw` prefix rule (under
"Socket Firewall"). This file holds what AGENTS.md does not: the Cargo and Bazel
dependency traps.

## Rust Dependency Management

Full detail, with the reasoning behind each rule: [rust/README_RUST.md](../../../rust/README_RUST.md).
The traps below are the ones an agent hits by accident.

- **Every dependency version lives in `[workspace.dependencies]` in the root `Cargo.toml`**,
  alphabetically sorted. A crate under `/rust/` NEVER names a version — it uses
  `{ workspace = true, features = [...] }`. Cargo and Bazel both read this one list, which
  is what keeps the two builds from drifting. (`sha2` in `rust/srql` is a documented
  exception; `rust/rdp-connector-probe` is deliberately detached.)
- **A green `cargo check` does NOT prove the Bazel build.** Finish every dependency change
  with `bazel build //rust/...`, and use `cargo check --workspace --lib --bins --tests` —
  plain `cargo check` skips test code that Bazel compiles.
- **`cargo check -p <crate>` must pass standalone.** Workspace feature unification hides a
  missing `features = [...]` behind another crate that enabled it.
- **`default-features = false` is only safe when the compiler catches the loss.** A dropped
  default that is a *runtime* backend compiles clean and fails in production — this exact
  mistake removed `ureq`'s TLS transport.
- **Refresh the vendored archives only with `bazel run //third_party/crate_mirror:sync`.**
  Source patches are `crate.annotation` `patches` entries applied at fetch time, so they
  are declared build inputs, not edits to a tree on disk.
- **OpenSSL comes from the `@openssl` BCR module** — never a vendored `openssl-src` build
  and never the machine's. Keep the `openssl-sys`/`pq-src` pairing in `//MODULE.bazel`, and
  set `OPENSSL_LIB_DIR`/`OPENSSL_INCLUDE_DIR` explicitly: `openssl-sys` reads them before
  `OPENSSL_DIR`, so the RBE executor's own OpenSSL gets linked silently otherwise.
- **`pq-src` is patched and pinned** (`pq-sys = "=0.7.5"`, patch in
  `//third_party/rust_patches/`). A bump that invalidates the patch fails the fetch loudly —
  do not paper over it; the patch is macOS-only, so skipping it leaves Linux CI green and
  breaks a developer's machine later.
- **Pass `cargo_only = True` to `all_crate_deps`**, and add the `@crates//:<name>` label by
  hand in any `BUILD.bazel` that lists deps explicitly — Bazel will not infer that one.
- **`rust_test(crate = ":x")` does NOT inherit `crate_features`** — repeat them, or the test
  compiles a different crate than the one that ships.
- **Every crate with `#[cfg(test)]` code needs a `rust_test` target.** flowgger silently
  carried a 2016 `serde_json` and fully broken config parsing because nothing ran its tests.
