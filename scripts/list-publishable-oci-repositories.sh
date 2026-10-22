#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=scripts/lib/fork-registry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fork-registry.sh"

inventory_file="${1:-docker/images/image_inventory.bzl}"

if [[ ! -f "${inventory_file}" ]]; then
  echo "inventory file not found: ${inventory_file}" >&2
  exit 1
fi

# The inventory holds image names; the registry and project come from the
# same variables the workflows and workspace status use.
repository_base="${OCI_REGISTRY}/${OCI_PROJECT}"
grep -Eo '"repository": "[^"]+"' "${inventory_file}" \
  | sed -E 's/.*"repository": "([^"]+)"/\1/' \
  | sed -E "s#^(.*/)?#${repository_base}/#" \
  | sort -u
