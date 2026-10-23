#!/usr/bin/env bash
# Every compose app image must be <fork prefix>/<name>:${APP_TAG:-latest} so that
# APP_TAG=local runs what `make compose-load-local` loaded. The prefix comes from
# scripts/lib/fork-registry.sh, so a rebrand that forgets compose fails here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

read -r registry project < <(env -u OCI_REGISTRY -u OCI_PROJECT bash -c '. scripts/lib/fork-registry.sh && echo "$OCI_REGISTRY $OCI_PROJECT"')
prefix="\${OCI_REGISTRY:-${registry}}/\${OCI_PROJECT:-${project}}/"
compose_files=(docker-compose.yml docker-compose.dev.yml)
fail=0

# CNPG stays on upstream's digest until the fork publishes it (docs/fork-ci.md, "Fork identity in code").
app_images() {
  grep -n -E 'image:.*(serviceradar-|/arancini:)' "$1" | grep -v 'serviceradar-cnpg' || true
}

for file in "${compose_files[@]}"; do
  bad=$(
    app_images "$file" | { grep -F -v "$prefix" || true; }
    app_images "$file" | { grep -F -v '${APP_TAG:-latest}' || true; }
  )
  if [[ -n "$bad" ]]; then
    echo "App images in $file must be ${prefix}<name>:\${APP_TAG:-latest}:" >&2
    echo "$bad" >&2
    fail=1
  fi
done

want=$(cat "${compose_files[@]}" | grep -o -E 'serviceradar-[a-z-]+:\$\{APP_TAG|/arancini:' \
  | sed -E 's/:.*//; s#^/##; s/^serviceradar-//; s/^arancini$/bmp_collector/; s/-/_/g' | sort -u)
have=$(sed -n -E 's/^COMPOSE_LOCAL_IMAGES \?= //p' Makefile | tr ' ' '\n' | sort -u)
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

[[ "$fail" -eq 0 ]] && echo "Compose image defaults look good."
exit "$fail"
