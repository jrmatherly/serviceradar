#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/fork-registry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fork-registry.sh"

if ! [[ "$#" -eq 1 || ( "$#" -eq 2 && "$2" == "--anonymous-ok" ) ]]; then
  echo "usage: $0 <chart-version> [--anonymous-ok]" >&2
  exit 1
fi

version="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${script_dir}/validate-release-tag.sh" "v${version}"

oci_registry="${OCI_REGISTRY}"
oci_chart_repository="${OCI_CHART_REPOSITORY:-${OCI_PROJECT}/charts}"
oci_chart_name="${OCI_CHART_NAME:-serviceradar}"
helm_runner="${SERVICERADAR_HELM_RUNNER:-}"

# Prefer an installed Helm binary. run-helm.sh now installs a native helm
# when needed; it no longer execs a container runtime.
if [[ -z "${helm_runner}" ]] && [[ -z "${CI:-}" ]] && command -v helm >/dev/null 2>&1; then
  helm_runner="$(command -v helm)"
fi

if [[ -z "${helm_runner}" ]]; then
  helm_runner="${script_dir}/run-helm.sh"
fi
chart_ref="oci://${oci_registry}/${oci_chart_repository}/${oci_chart_name}"

set +e
probe_output="$("${helm_runner}" show chart "${chart_ref}" --version "${version}" 2>&1)"
probe_status=$?
set -e

if [[ "${probe_status}" -eq 0 ]]; then
  echo "Refusing release version ${version}: OCI Helm chart already exists at ${chart_ref}:${version}." >&2
  echo "Published chart versions are immutable; select a new product version." >&2
  exit 1
fi

absent_pattern='manifest unknown|manifest_unknown|no such manifest|(^|: )[[:space:]]*not found([[:space:]]|$)'
# GHCR refuses an anonymous token for a package that does not exist yet
# (oras-go v2 and v1 wordings). CI probes with credentials and never passes
# this flag.
if [[ "${2:-}" == "--anonymous-ok" ]]; then
  absent_pattern+='|ghcr\.io/token\?.*(response status code 403: denied|: 403 Forbidden)'
fi

if grep -Eiq "${absent_pattern}" <<<"${probe_output}"; then
  echo "OCI Helm chart version ${version} is available."
  exit 0
fi

echo "Unable to verify OCI Helm chart occupancy for ${chart_ref}:${version}." >&2
echo "${probe_output}" >&2
exit 2
