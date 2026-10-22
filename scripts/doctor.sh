#!/usr/bin/env bash
# Not a Bazel target: this checks the developer machine itself (toolchains, hooks,
# local files), which a hermetic Bazel action cannot see.
#
# Usage: make doctor
# Exit 1 when any FAIL row fails; WARN rows never change the exit status.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

makefile_var() {
  sed -n "s/^$1 ?= //p" Makefile | head -1
}

capped() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${secs}" "$@"
  else
    "$@"
  fi
}

# `mise current` prints the pinned version even when it is not installed; `mise where`
# exits non-zero in that case.
mise_pinned() {
  [ "$(capped 20 mise current "$1" 2>/dev/null)" = "$2" ] && capped 20 mise where "$1" >/dev/null 2>&1
}

rust_channel_active() {
  local active
  active="$(capped 20 rustup show active-toolchain 2>/dev/null)" || return 1
  case "${active}" in
    "$1"-*) return 0 ;;
    *) return 1 ;;
  esac
}

# A bare `ls ~/.cache/pre-commit/repo*` passes on any cached hook repo (markdownlint,
# a stale gitleaks rev). pre-commit's own db.db maps the configured repo and rev to its
# clone, and the env's .install_state_v2 is written only after the install completes.
gitleaks_hook_installed() {
  local rev db clone
  command -v pre-commit >/dev/null 2>&1 || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  rev="$(awk '/repo: https:\/\/github.com\/gitleaks\/gitleaks/ {f=1; next} f && /rev:/ {print $2; exit}' .pre-commit-config.yaml)"
  [ -n "${rev}" ] || return 1
  db="${PRE_COMMIT_HOME:-${HOME}/.cache/pre-commit}/db.db"
  [ -f "${db}" ] || return 1
  clone="$(sqlite3 "${db}" "select path from repos where repo = 'https://github.com/gitleaks/gitleaks' and ref = '${rev}' limit 1" 2>/dev/null)"
  [ -n "${clone}" ] || return 1
  ls "${clone}"/*env-default/.install_state_v2 >/dev/null 2>&1
}

mix_deps_fetched() {
  local out
  out="$(cd "elixir/$1" && capped 120 env MIX_ENV=test mix deps --all 2>/dev/null)" || return 1
  ! printf '%s\n' "${out}" | grep -q 'not available'
}

escript_at_version() {
  [ -x "$1" ] && [ "$(capped 30 "$1" --version 2>/dev/null)" = "$2" ]
}

golangci_lint_matches_or_absent() {
  local found
  command -v golangci-lint >/dev/null 2>&1 || return 0
  found="$(capped 20 golangci-lint version --short 2>/dev/null)" || return 1
  [ "v${found#v}" = "$1" ]
}

on_path() {
  command -v "$1" >/dev/null 2>&1
}

hooks_path_is_githooks() {
  [ "$(git config core.hooksPath)" = .githooks ]
}

commit_email_set() {
  [ -n "$(git config user.email)" ]
}

check_names=()
check_levels=()
check_probes=()
check_fixes=()

check() {
  check_names+=("$1")
  check_levels+=("$2")
  check_probes+=("$3")
  check_fixes+=("$4")
}

while read -r tool version _; do
  case "${tool}" in ''|\#*) continue ;; esac
  check "mise ${tool} ${version}" fail "mise_pinned $(printf %q "${tool}") $(printf %q "${version}")" "mise install"
done < .tool-versions

rust_channel="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)"
check "rust toolchain ${rust_channel}" fail "rust_channel_active $(printf %q "${rust_channel}")" "rustup toolchain install ${rust_channel}"

check "git hooks path" fail hooks_path_is_githooks "make hooks-setup"
check "pre-commit gitleaks env" fail gitleaks_hook_installed "make hooks-setup"

for project in $(makefile_var ELIXIR_PROJECTS); do
  check "mix deps ${project}" fail "mix_deps_fetched $(printf %q "${project}")" "cd elixir/${project} && mix deps.get"
done

protobuf_version="$(makefile_var ELIXIR_PROTOBUF_VERSION)"
protoc_gen_elixir="${MIX_HOME:-${HOME}/.mix}/escripts/protoc-gen-elixir"
check "protoc-gen-elixir ${protobuf_version}" fail \
  "escript_at_version $(printf %q "${protoc_gen_elixir}") $(printf %q "${protobuf_version}")" \
  "make install-protoc-gen-elixir"

check protoc fail "on_path protoc" "brew install protobuf"
check bats fail "on_path bats" "brew install bats-core"
check gitleaks fail "on_path gitleaks" "brew install gitleaks"
check rg fail "on_path rg" "brew install ripgrep"
check bun fail "on_path bun" "mise use -g bun"
check bazel fail "on_path bazel || on_path bazelisk" "brew install bazelisk"
check helm fail "on_path helm" "mise use -g helm"
check kubectl fail "on_path kubectl" "mise use -g kubectl"
check docker fail "on_path docker" "brew install docker (plus a runtime such as OrbStack or Docker Desktop)"
check pkgconf fail "on_path pkgconf" "brew install pkgconf"
check shellcheck fail "on_path shellcheck" "mise use -g shellcheck"
check jq fail "on_path jq" "mise use -g jq"

check sfw fail "on_path sfw" \
  "SFW_INSTALL_DIR=~/.local/bin scripts/ci/install-sfw.sh (verifies the published sha256; then put ~/.local/bin on PATH)"

check ".bazelrc.remote" fail "[ -e .bazelrc.remote ]" \
  "read -rs BUILDBUDDY_ORG_API_KEY && export BUILDBUDDY_ORG_API_KEY && scripts/ci/configure-bazel-remote.sh; unset BUILDBUDDY_ORG_API_KEY"
check "git user.email" fail commit_email_set "git config user.email <your address> (commit identity is content; see AGENTS.md)"

check timeout warn "on_path timeout || on_path gtimeout" "brew install coreutils (without it, slow probes such as mix deps run uncapped)"
check ".env" warn "[ -e .env ]" "cp .env-sample .env"
check ".local-dev-certs" warn "[ -d .local-dev-certs ]" \
  "docs/agent-runbooks.md, Local Development with Docker CNPG, step 2"
check "node_modules js/cli" warn "[ -d js/cli/node_modules ]" "cd js/cli && sfw npm ci"
check "node_modules js/create-dashboard" warn "[ -d js/create-dashboard/node_modules ]" "cd js/create-dashboard && sfw npm ci"
check "node_modules docs" warn "[ -d docs/node_modules ]" "cd docs && sfw npm ci"
check "node_modules elixir/web-ng/assets" warn "[ -d elixir/web-ng/assets/node_modules ]" "cd elixir/web-ng/assets && sfw bun install"

golangci_lint_version="$(makefile_var GOLANGCI_LINT_VERSION)"
check "golangci-lint on PATH is ${golangci_lint_version}" warn \
  "golangci_lint_matches_or_absent $(printf %q "${golangci_lint_version}")" \
  "use make lint-go, which runs the pinned copy in GOLANGCI_LINT_DIR (a bare golangci-lint of another version reports different findings), or brew uninstall golangci-lint"

failed=0
i=0
while [ "${i}" -lt "${#check_names[@]}" ]; do
  if eval "${check_probes[$i]}" >/dev/null 2>&1; then
    log "OK   ${check_names[$i]}"
  elif [ "${check_levels[$i]}" = fail ]; then
    log "FAIL ${check_names[$i]}: ${check_fixes[$i]}"
    failed=1
  else
    log "WARN ${check_names[$i]}: ${check_fixes[$i]}"
  fi
  i=$((i + 1))
done

if [ "${failed}" -ne 0 ]; then
  err "doctor: at least one FAIL row; run the fix it names and re-run make doctor"
  exit 1
fi
