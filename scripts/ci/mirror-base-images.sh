#!/usr/bin/env bash
# Mirrors every base image that MODULE.bazel pulls (oci_ext.pull) into the fork's
# registry, by digest, so Bazel never depends on Docker Hub or another
# organisation's registry. Copying by digest preserves the digest, so the pins
# in MODULE.bazel do not change; only the `image =` host does.
#
#   scripts/ci/mirror-base-images.sh --list   print "<src>@<digest> -> <dest>" and exit
#   scripts/ci/mirror-base-images.sh          copy each image (crane) and verify the digest
#
# Env: OCI_REGISTRY (default ghcr.io), OCI_PROJECT (default jrmatherly).
# Destination: ${OCI_REGISTRY}/${OCI_PROJECT}/mirror/<path>:mirror-<digest[7:19]>, where
# <path> is the source path without its registry host and without a leading "mirror/".
# Registry auth for pushes comes from `crane auth login` (the workflow does it).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
registry="${OCI_REGISTRY:-ghcr.io}"
project="${OCI_PROJECT:-jrmatherly}"
mode="${1:-copy}"

# One "<image> <digest>" line per oci_ext.pull block.
mapfile -t entries < <(
  python3 - "${REPO_ROOT}/MODULE.bazel" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for block in re.findall(r"oci_ext\.pull\((.*?)\n\)", text, re.S):
    image = re.search(r'^\s*image = "([^"]+)"', block, re.M)
    digest = re.search(r'^\s*digest = "(sha256:[0-9a-f]{64})"', block, re.M)
    if not image or not digest:
        raise SystemExit(f"oci_ext.pull without image/digest: {block[:80]!r}")
    print(image.group(1), digest.group(1))
PY
)
[[ ${#entries[@]} -gt 0 ]] || { echo "no oci_ext.pull entries found in MODULE.bazel" >&2; exit 1; }

dest_for() {
  local image="$1" digest="$2" path
  path="${image#*/}"                 # drop the registry host
  path="${path%%:*}"                 # drop any :tag
  path="${path#mirror/}"             # the source may already be a mirror
  printf '%s/%s/mirror/%s:mirror-%s\n' "${registry}" "${project}" "${path}" "${digest:7:12}"
}

status=0
for entry in "${entries[@]}"; do
  read -r image digest <<<"${entry}"
  src="${image%%:*}@${digest}"      # pull by digest; a :tag on the source is informational
  dest="$(dest_for "${image}" "${digest}")"
  if [[ "${mode}" == "--list" ]]; then
    printf '%s@%s -> %s\n' "${image}" "${digest}" "${dest}"
    continue
  fi
  echo "mirroring ${src} -> ${dest}"
  crane copy "${src}" "${dest}"
  got="$(crane digest "${dest}")"
  if [[ "${got}" != "${digest}" ]]; then
    echo "error: ${dest} has digest ${got}, expected ${digest}" >&2
    status=1
  fi
done
exit "${status}"
