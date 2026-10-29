#!/usr/bin/env bash
# Fails when a change moves one of the two web-ng asset lockfiles without the
# other. bun.lock feeds `bun install --frozen-lockfile` (dev setup and
# web-ng-lint.yml); pnpm-lock.yaml is the Bazel release input. A change that
# updates only one leaves the other install broken.
# Usage: scripts/check-web-ng-lockfiles.sh <base-ref> [<head-ref>]
set -euo pipefail

base="${1:?base ref}"
head="${2:-HEAD}"
changed=$(git diff --name-only "$base" "$head" -- elixir/web-ng/assets/bun.lock elixir/web-ng/assets/pnpm-lock.yaml)
count=$(printf '%s\n' "$changed" | grep -c . || true)

if [[ "$count" -eq 1 ]]; then
  echo "Only one web-ng asset lockfile changed between $base and $head:" >&2
  echo "$changed" >&2
  echo "Update bun.lock (bun 1.3.9) and pnpm-lock.yaml (pnpm 10, --lockfile-only) together." >&2
  exit 1
fi
echo "web-ng asset lockfiles move together ($count changed)."
