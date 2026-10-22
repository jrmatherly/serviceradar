#!/usr/bin/env bash
set -euo pipefail

version="${SFW_VERSION:-v1.15.0}"
# CI installs under the runner temp dir; a developer machine passes SFW_INSTALL_DIR=~/.local/bin.
install_dir="${SFW_INSTALL_DIR:-${RUNNER_TEMP:-/tmp}/socket-firewall}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    asset="sfw-free-linux-x86_64"
    sha256="c80371910a808ea5c68916c48e5451716a91ca411cf5e422fdbd8119729b742c"
    ;;
  Linux-aarch64|Linux-arm64)
    asset="sfw-free-linux-arm64"
    sha256="55671fa409ef3d40fcee66acbba4d7acfff8a5332d349ad47cca809ebf473cd0"
    ;;
  Darwin-arm64)
    asset="sfw-free-macos-arm64"
    sha256="fa473291b8b76220f4b636cf655e8a4dc03332145bdea3acfd9bc96887b2da20"
    ;;
  Darwin-x86_64)
    asset="sfw-free-macos-x86_64"
    sha256="07cfcc9805812130ebca07f73c51c2cd9c0181b394f25be4c969c0d31c9dc26f"
    ;;
  *)
    echo "unsupported Socket Firewall runner platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "${install_dir}"
sfw_path="${install_dir}/sfw"

curl -fsSL --retry 3 \
  "https://github.com/SocketDev/sfw-free/releases/download/${version}/${asset}" \
  -o "${sfw_path}"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "${sha256}" "${sfw_path}" | sha256sum -c -
else
  actual="$(shasum -a 256 "${sfw_path}" | awk '{print $1}')"
  test "${actual}" = "${sha256}"
fi

chmod +x "${sfw_path}"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${install_dir}" >> "${GITHUB_PATH}"
else
  echo "Add ${install_dir} to PATH to use sfw in later steps." >&2
fi

"${sfw_path}" --help
