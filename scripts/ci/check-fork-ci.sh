#!/usr/bin/env bash
# Fork CI acceptance check: actionlint must be clean, and nothing the fork's CI
# reads may name upstream (carverauto) infrastructure. See docs/fork-ci.md.
#
# Exit 0 = clean. Otherwise every offending file:line is printed and exit 1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0

if ! actionlint -no-color; then
  status=1
fi

# Non-comment lines only: a comment may explain what was removed.
pattern='registry\.carverauto\.dev|carverauto\.buildbuddy\.io|cache-proxy\.carverauto\.dev|serviceradar-signing|arc-runner-set|HARBOR_|OPENBAO_ADDR: https://openbao|hashivault://cosign-release|github-signing-runner|svc\.cluster\.local|mfreeman'

paths=(.github buildbuddy.yaml .bazelrc build/rbe/BUILD docker/Dockerfile.rbe)
paths+=(build/ci/*.py)

hits="$(grep -rnE "${pattern}" "${paths[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}"
  status=1
fi

exit "${status}"
