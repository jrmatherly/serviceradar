# Conventions

- Go: `gofmt`, organized imports, reuse `go/pkg` helpers; new deps need `go.mod` + Bazel `MODULE.bazel`(+lock) updates. Prefer Bazel targets where BUILD files exist.
- Rust: `cargo fmt` + `cargo clippy` on touched crates (`./scripts/lint-rust.sh`); reuse Diesel/CNPG helpers.
- Elixir/Ash: use `Ash.Changeset.for_create/for_update` and `Ash.Query.for_read`; pass `scope:` (not separate `actor:`); no `require_atomic? false` shortcuts; validations' `atomic/3` must delegate, never bare `:ok`; enforce state invariants via DB `check_constraint`/policies/notifiers. Details in `elixir/web-ng/AGENTS.md`.
- Phoenix 1.8: templates start with `<Layouts.app flash={@flash} ...>`; use `<.icon>`, `<.input>`; `<.flash_group>` only in layouts.ex; Req with explicit `retry` policy for outbound HTTP.
- Docs: runbooks go in `docs/` root; `docs/docs/` is published Docusaurus; Markdown ASCII only.
- Generators first for scaffolding.
- Fixtures: synthetic only (RFC 5737 IPs, `example.com` hosts, 555-01xx phones). Anchor search patterns.
- Comments: describe failure mode, never a customer/site/ticket.
- Planning/proposals: follow `openspec/AGENTS.md`.
- Commits/PRs: no affected-party names; verify `git config user.email` per clone/worktree.
