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

# buildbuddy.yaml actions marked "Disabled on the fork" keep their upstream definition
# for manual use; lines inside them are not findings.
disabled_ranges="$(awk '
  /^  - name: / { if (dis) printf "%d-%d ", start, NR-1; dis=0; start=NR }
  /# Disabled on the fork/ { dis=1 }
  END { if (dis) printf "%d-%d ", start, NR }
' buildbuddy.yaml)"
if [[ -n "${disabled_ranges}" ]]; then
  hits="$(printf '%s\n' "${hits}" | awk -v ranges="${disabled_ranges}" '
    BEGIN { n = split(ranges, r, " ") }
    /^buildbuddy\.yaml:/ {
      split($0, f, ":"); ln = f[2] + 0
      for (i = 1; i <= n; i++) { split(r[i], ab, "-"); if (ln >= ab[1] && ln <= ab[2]) next }
    }
    { print }
  ' | sed '/^$/d')"
fi
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}"
  status=1
fi

exit "${status}"
