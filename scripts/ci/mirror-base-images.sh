#!/usr/bin/env bash
# Mirrors every base image that MODULE.bazel pulls (oci_ext.pull) into the fork's
# registry, by digest, so Bazel never depends on Docker Hub or another
# organisation's registry. MODULE.bazel names the MIRROR (ghcr.io/<owner>/mirror/<path>);
# docker/images/base_image_origins.txt maps each <path> to the image's origin. The copy
# is by digest, so the digest pinned in MODULE.bazel is exactly what lands in the mirror.
#
#   scripts/ci/mirror-base-images.sh --list   print "<origin>@<digest> -> <mirror ref>" and exit
#   scripts/ci/mirror-base-images.sh          copy each image (crane) and verify the digest
#
# Registry auth for pushes comes from `crane auth login` (the workflow does it).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
origins_file="${REPO_ROOT}/docker/images/base_image_origins.txt"
mode="${1:-copy}"

origin_for() {
  # <mirror path without tag> -> origin reference, from the manifest
  local path="$1" line
  line="$(grep -E "^${path} " "${origins_file}" || true)"
  [[ -n "${line}" ]] || { echo "error: no origin for ${path} in ${origins_file}" >&2; return 1; }
  printf '%s\n' "${line#* }"
}

# One "<mirror image ref> <digest>" line per oci_ext.pull block.
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

status=0
for entry in "${entries[@]}"; do
  read -r mirror digest <<<"${entry}"
  # mirror = <registry>/<owner>/mirror/<path>[:tag]
  path="${mirror#*/mirror/}"
  path="${path%%:*}"
  if [[ "${path}" == "${mirror}" ]]; then
    echo "error: ${mirror} is not under a /mirror/ namespace; MODULE.bazel must name the fork's mirror" >&2
    status=1; continue
  fi
  origin="$(origin_for "${path}")" || { status=1; continue; }
  src="${origin}@${digest}"
  if [[ "${mode}" == "--list" ]]; then
    printf '%s -> %s\n' "${src}" "${mirror}"
    continue
  fi
  echo "mirroring ${src} -> ${mirror}"
  # GHCR has returned DENIED on a child-manifest PUT the first time a new package is
  # created and accepted the identical push moments later; retry before giving up.
  copied=0
  for attempt in 1 2 3; do
    if crane copy "${src}" "${mirror}"; then copied=1; break; fi
    echo "crane copy attempt ${attempt} failed; retrying in 15s" >&2
    sleep 15
  done
  if [[ "${copied}" -ne 1 ]]; then
    echo "error: could not mirror ${src}" >&2
    status=1
    continue
  fi
  got="$(crane digest "${mirror}")"
  if [[ "${got}" != "${digest}" ]]; then
    echo "error: ${mirror} has digest ${got}, expected ${digest}" >&2
    status=1
  fi
done
exit "${status}"
