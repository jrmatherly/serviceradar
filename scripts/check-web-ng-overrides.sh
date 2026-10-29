#!/usr/bin/env bash
# bun reads `overrides` and pnpm (the Bazel release input) reads `pnpm.overrides`, so a pin in only
# one of them ships different dependency trees to dev and to release. A pnpm "-" (remove the package)
# is exempt: bun 1.3.9 has no removal syntax and fails to resolve "-" as a version.
# Nested "a>b" keys are compared too, though bun 1.3.9 ignores them.
set -euo pipefail

pkg=${1:-$(git rev-parse --show-toplevel)/elixir/web-ng/assets/package.json}
diff=$(jq -r '(.pnpm.overrides // {}) as $p | (.overrides // {}) as $b
  | ($p + $b | keys[]) | select($p[.] != $b[.] and ($p[.] != "-" or $b[.] != null))
  | "\(.)\tpnpm.overrides=\($p[.] // "<absent>")\toverrides=\($b[.] // "<absent>")"' "$pkg")

if [[ -n "$diff" ]]; then
  echo "$pkg: pnpm.overrides and overrides differ:" >&2
  echo "$diff" >&2
  exit 1
fi
echo "$pkg: pnpm.overrides and overrides match"
