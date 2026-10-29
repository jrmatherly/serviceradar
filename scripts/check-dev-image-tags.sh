#!/usr/bin/env bash
# Every compose app image must be <fork prefix>/<name>:${APP_TAG:-latest} so that
# APP_TAG=local runs what `make compose-load-local` loaded. The prefix comes from
# scripts/lib/fork-registry.sh, so a rebrand that forgets compose fails here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

read -r registry project < <(env -u OCI_REGISTRY -u OCI_PROJECT bash -c '. scripts/lib/fork-registry.sh && echo "$OCI_REGISTRY $OCI_PROJECT"')
prefix="\${OCI_REGISTRY:-${registry}}/\${OCI_PROJECT:-${project}}/"
prefix_re=$(printf '%s' "$prefix" | sed 's/[$.{}]/\\&/g')
compose_files=(docker-compose.yml docker-compose.dev.yml)
# Images compose runs that the fork does not build, plus CNPG, which carries a PostgreSQL
# version tag and digest rather than APP_TAG, so only its prefix is checked here.
cnpg="${registry}/${project}/serviceradar-cnpg"
cnpg_re="${cnpg//./\\.}"
third_party='(\$\{[A-Z_]+:-)?(alpine|caddy|docker|nats|pgsty/|pgduckdb/|starrocks/|dgraph/|'"${cnpg_re}"')'
fail=0

for file in "${compose_files[@]}"; do
  [[ -r "$file" ]] || { echo "missing $file" >&2; exit 1; }
done

app_lines=$(grep -n -H -E '^[[:space:]]+image:' "${compose_files[@]}" | { grep -v -E "image:[[:space:]]*${third_party}" || true; })
[[ -n "$app_lines" ]] || { echo "no app images found in ${compose_files[*]}; the image pattern in $0 drifted" >&2; exit 1; }

bad=$(printf '%s\n' "$app_lines" | { grep -v -E "image:[[:space:]]*(\\\$\\{[A-Z_]+:-)?${prefix_re}[a-z0-9-]+:\\\$\\{APP_TAG:-latest\\}\\}?\$" || true; })
if [[ -n "$bad" ]]; then
  echo "App images must be ${prefix}<name>:\${APP_TAG:-latest} (third-party images go in the allowlist in $0):" >&2
  echo "$bad" >&2
  fail=1
fi

want=$(printf '%s\n' "$app_lines" | { grep -o -E "${prefix_re}[a-z0-9-]+:" || true; } \
  | sed -E 's#^.*/##; s/:$//; s/^serviceradar-//; s/^arancini$/bmp_collector/; s/-/_/g' | sort -u)
have=$(sed -n -E 's/^COMPOSE_LOCAL_IMAGES *[?:]?= *//p' Makefile | tr ' ' '\n' | sort -u)
[[ -n "$have" ]] || { echo "COMPOSE_LOCAL_IMAGES not found in Makefile" >&2; exit 1; }
missing=$(comm -23 <(echo "$want") <(echo "$have"))
if [[ -n "$missing" ]]; then
  echo "Add to COMPOSE_LOCAL_IMAGES in Makefile (compose uses them, make compose-load-local would skip them):" >&2
  echo "$missing" >&2
  fail=1
fi

if ! grep -q -E 'static_tags = \["latest"\] \+ target.get\("static_tags", \[\]\)' docker/images/push_targets.bzl; then
  echo "Expected docker/images/push_targets.bzl to include latest in static tags." >&2
  fail=1
fi

# Every CNPG pin site must carry the same digest, so a bump that misses one fails here.
cnpg_pins=(docker-compose.yml docker/compose/test-db/compose.yml docker/compose/migrate-cnpg-pg16-to-pg18.sh)
cnpg_digests=$({ grep -h -o -E "${cnpg_re}[^@[:space:]]*@sha256:[0-9a-f]{64}" "${cnpg_pins[@]}" || true; } | sed 's/.*@//' | sort -u)
if [[ $(printf '%s\n' "$cnpg_digests" | grep -c .) -ne 1 ]]; then
  echo "CNPG pins must agree on one ${cnpg} digest across ${cnpg_pins[*]}; found:" >&2
  { grep -n -H -E "${cnpg_re}" "${cnpg_pins[@]}" || true; } >&2
  fail=1
fi

[[ "$fail" -eq 0 ]] && echo "Compose image defaults look good."
exit "$fail"
