#!/usr/bin/env bash
# End-to-end check that revoking a collector package makes the hub refuse its NATS
# credential, on a running Compose stack. It restarts NATS to prove the revocation
# survives the init containers. Every step exits non-zero on anything but the
# expected result; a refusal must be the hub's authorization error, not a timeout.
#
# Environment: SR_URL (default http://localhost), SR_ADMIN_EMAIL (default
# root@localhost), SR_NETWORK (default serviceradar_serviceradar-net) and
# SR_TOOLS_IMAGE (default the running stack's tools image). Start the stack with
# SERVICERADAR_NATS_COLLECTOR_URL=tls://nats.serviceradar:4222.
set -euo pipefail

url="${SR_URL:-http://localhost}"
email="${SR_ADMIN_EMAIL:-root@localhost}"
network="${SR_NETWORK:-serviceradar_serviceradar-net}"
tools_image="${SR_TOOLS_IMAGE:-$(docker inspect --format '{{.Config.Image}}' serviceradar-nats-account-limits)}"
nats_url="tls://nats.serviceradar:4222"
refusal="Authorization Violation"

work="$(mktemp -d)"
chmod 0755 "${work}"
packages=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "${method}" -H "authorization: Bearer ${token}" \
    -H 'content-type: application/json' "$@" "${url}${path}"
}

cleanup() {
  for id in ${packages[@]+"${packages[@]}"}; do
    api POST "/api/admin/collectors/${id}/revoke" -d '{"reason":"revocation check cleanup"}' -o /dev/null || true
  done
  rm -rf "${work}"
}
trap cleanup EXIT

# /api/admin takes a bearer token, not a browser session. rpc prints a TLS notice first.
mint_token() {
  token="$(rpc "
    actor = ServiceRadar.Actors.SystemActor.system(:revocation_check)
    {:ok, user} = ServiceRadar.Identity.User.get_by_email(\"${email}\", actor: actor)
    {:ok, token, _claims} = ServiceRadarWebNG.Auth.Guardian.create_access_token(user)
    IO.puts(token)")"
  [ "$(api GET /api/admin/nats/credentials -o /dev/null -w '%{http_code}')" = 200 ] || fail "the minted token was refused"
}

rpc() {
  docker exec serviceradar-web-ng-mtls bin/serviceradar_web_ng rpc "$1" | tail -1
}

# Sets provisioned to a new trapd package that is ready, created and downloaded the way
# an operator does, with its bundle extracted in work/<id>. The stack needs
# SERVICERADAR_NATS_COLLECTOR_URL set, or the bundle endpoint refuses hub-direct packages.
provision() {
  local name="$1" id status body="" enrollment bundle_dir
  body="$(api POST /api/admin/collectors \
    -d "{\"collector_type\":\"trapd\",\"site\":\"revocation-check\",\"hostname\":\"${name}.example.com\"}")"
  id="$(jq -r .id <<<"${body}")"
  enrollment="$(jq -r .enrollment_token <<<"${body}")"
  [[ "${id}" =~ ^[0-9a-f-]{36}$ ]] || fail "create package answered: ${body}"
  [ "${enrollment}" != null ] || fail "create package returned no enrollment token: ${body}"
  packages+=("${id}")

  status=""
  for _ in $(seq 1 60); do
    body="$(api GET "/api/admin/collectors/${id}")"
    status="$(jq -r .status <<<"${body}")"
    [ "${status}" = ready ] && break
    [ "${status}" = failed ] && fail "package ${name} failed: $(jq -r .error_message <<<"${body}")"
    sleep 2
  done
  [ "${status}" = ready ] || fail "package ${name} stuck in ${status}: ${body}"

  mkdir -p "${work}/${id}"
  curl -fsS -X POST -H "x-serviceradar-download-token: ${enrollment}" \
    -o "${work}/${id}/bundle.tar.gz" "${url}/api/collectors/${id}/bundle" || fail "bundle download failed for ${name}"
  tar -xzf "${work}/${id}/bundle.tar.gz" -C "${work}/${id}"
  bundle_dir="$(find "${work}/${id}" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -x "${bundle_dir}/update.sh" ] || fail "package ${name}: update.sh is not executable"
  [ "$(stat -f %Lp "${bundle_dir}/certs/collector-key.pem" 2>/dev/null || stat -c %a "${bundle_dir}/certs/collector-key.pem")" = 600 ] ||
    fail "package ${name}: the private key is not 0600"
  jq -er --arg url "${nats_url}" 'select(.nats_url == $url)' "${bundle_dir}/config/trapd.json" >/dev/null ||
    fail "package ${name}: the bundle does not name ${nats_url}"
  local file
  for file in certs/collector.pem certs/collector-key.pem certs/ca-chain.pem creds/nats.creds; do
    # The nats CLI runs as another uid in a container; this copy dies with the trap.
    cp "${bundle_dir}/${file}" "${work}/${id}/$(basename "${file}")"
    chmod 0644 "${work}/${id}/$(basename "${file}")"
  done
  provisioned="${id}"
}

# Publishes logs.snmp with package $1's certificate; "creds" adds its NATS credential.
publish() {
  local id="$1" auth="${2:-creds}" args=()
  args=(--server "${nats_url}"
    --tlscert "/work/${id}/collector.pem"
    --tlskey "/work/${id}/collector-key.pem"
    --tlsca "/work/${id}/ca-chain.pem")
  [ "${auth}" = creds ] && args+=(--creds "/work/${id}/nats.creds")
  docker run --rm --network "${network}" --entrypoint nats -v "${work}:/work:ro" "${tools_image}" \
    "${args[@]}" --timeout 5s pub logs.snmp revocation-check 2>&1
}

expect_accepted() {
  local out
  out="$(publish "$1")" || fail "$2: the hub should accept this credential, got: ${out}"
  echo "ok: $2"
}

expect_refused() {
  local out
  if out="$(publish "$1" "${3:-creds}")"; then
    fail "$2: the hub accepted it: ${out}"
  fi
  grep -q "${refusal}" <<<"${out}" || fail "$2: failed for another reason than '${refusal}': ${out}"
  echo "ok: $2"
}

mint_token

provision revoke-target-check
target="${provisioned}"
provision revoke-control-check
control="${provisioned}"

expect_accepted "${target}" "the target's credential works before revocation"
expect_accepted "${control}" "the control's credential works"
expect_refused "${target}" "a package certificate without a NATS credential is refused" cert-only

body="$(api POST "/api/admin/collectors/${target}/revoke" -d '{"reason":"revocation check"}')"
[ "$(jq -r .status <<<"${body}")" = revoked ] || fail "revoke answered: ${body}"
echo "ok: the API reports the package revoked"

expect_refused "${target}" "the revoked credential is refused"
expect_accepted "${control}" "the control survives another package's revocation"

docker start -a serviceradar-nats-account-limits >/dev/null
docker start -a serviceradar-nats-config-init >/dev/null
docker restart serviceradar-nats-mtls >/dev/null
for _ in $(seq 1 30); do
  publish "${control}" >/dev/null && break
  sleep 2
done

expect_accepted "${control}" "the control works after the NATS init containers and a restart"
expect_refused "${target}" "the revocation survives the NATS init containers and a restart"

echo "PASS: the hub refuses the revoked package's credential"
