#!/usr/bin/env bash
# Registry inspect helpers that do not need skopeo or dockerd.
# Requires oras + jq + curl. Used by release publish/verify.

oci_registry_digest() {
  local ref="$1"
  local desc digest
  if ! command -v oras >/dev/null 2>&1; then
    echo "error: oras is required to inspect ${ref}" >&2
    return 2
  fi
  if ! desc="$(oras manifest fetch --descriptor "${ref}" 2>&1)"; then
    printf '%s\n' "${desc}" >&2
    return 1
  fi
  digest="$(jq -r '.digest // empty' <<<"${desc}")"
  if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: invalid descriptor digest for ${ref}: ${desc}" >&2
    return 2
  fi
  printf '%s\n' "${digest}"
}

oci_registry_manifest() {
  local ref="$1"
  shift
  if ! command -v oras >/dev/null 2>&1; then
    echo "error: oras is required to fetch ${ref}" >&2
    return 2
  fi
  # oras 1.3 still prints manifests to stdout; --output - keeps that contract
  # if a later oras tightens the same required-flag rule as blob fetch.
  oras manifest fetch --output - "$@" "${ref}"
}

oci_registry_platform_manifest() {
  local ref="$1"
  local os="${2:-linux}"
  local arch="${3:-amd64}"
  local raw media_type digest
  raw="$(oci_registry_manifest "${ref}")" || return $?
  media_type="$(jq -r '.mediaType // empty' <<<"${raw}")"
  case "${media_type}" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
      digest="$(
        jq -r --arg os "${os}" --arg arch "${arch}" '
          .manifests[]
          | select(.platform.os == $os and .platform.architecture == $arch)
          | .digest
        ' <<<"${raw}" | head -n1
      )"
      if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "error: ${ref} has no ${os}/${arch} manifest" >&2
        return 1
      fi
      oci_registry_manifest "${ref%@*}@${digest}"
      ;;
    *)
      printf '%s\n' "${raw}"
      ;;
  esac
}

oci_registry_config() {
  local ref="$1"
  local os="${2:-linux}"
  local arch="${3:-amd64}"
  local manifest config_digest
  manifest="$(oci_registry_platform_manifest "${ref}" "${os}" "${arch}")" || return $?
  config_digest="$(jq -r '.config.digest // empty' <<<"${manifest}")"
  if [[ ! "${config_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: ${ref} is missing a config digest" >&2
    return 1
  fi
  # oras 1.3 blob fetch refuses to write to stdout unless --output is set.
  oras blob fetch --output - "${ref%@*}@${config_digest}"
}

# Bearer token for one repository, discovered from the registry's own
# WWW-Authenticate challenge so the same code works against GHCR (/token),
# Harbor (/service/token) and any other distribution-compliant registry.
#
#   oci_registry_token <repo_path> [scope_actions=pull] [user] [pass]
#
# REGISTRY_HOST must be set. Credentials fall back to OCI_USERNAME/OCI_TOKEN.
oci_registry_token() {
  local repo_path="$1"
  local scope_actions="${2:-pull}"
  local user="${3:-${OCI_USERNAME:-}}"
  local pass="${4:-${OCI_TOKEN:-}}"
  local challenge realm service token_url token

  challenge="$(curl -sS --max-time 20 -o /dev/null -D - "https://${REGISTRY_HOST}/v2/" | tr -d '\r' | { grep -i '^www-authenticate: bearer' || true; } | head -n1)"
  if [[ -z "${challenge}" ]]; then
    echo "error: ${REGISTRY_HOST} returned no bearer challenge for /v2/" >&2
    return 2
  fi
  realm="$(sed -nE 's/.*realm="([^"]+)".*/\1/p' <<<"${challenge}")"
  service="$(sed -nE 's/.*service="([^"]+)".*/\1/p' <<<"${challenge}")"
  if [[ -z "${realm}" ]]; then
    echo "error: could not parse the bearer realm from ${REGISTRY_HOST}: ${challenge}" >&2
    return 2
  fi
  token_url="${realm}?scope=repository:${repo_path}:${scope_actions}"
  if [[ -n "${service}" ]]; then
    token_url+="&service=${service}"
  fi
  if [[ -n "${user}" && -n "${pass}" ]]; then
    token="$(curl -fsSL -u "${user}:${pass}" "${token_url}" | jq -r '.token // .access_token // empty')"
  else
    token="$(curl -fsSL "${token_url}" | jq -r '.token // .access_token // empty')"
  fi
  if [[ -z "${token}" ]]; then
    echo "error: token lookup for ${repo_path} (${scope_actions}) failed at ${realm}" >&2
    return 1
  fi
  printf '%s\n' "${token}"
}
