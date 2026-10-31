#!/usr/bin/env bash
# End-to-end check that revoking a collector package makes the hub refuse its NATS
# credential, on a running Compose stack. It restarts NATS to prove the revocation
# survives the init containers. Every step exits non-zero on anything but the
# expected result; a refusal must be the hub's authorization error, not a timeout.
#
# Environment: SR_URL (default http://localhost), SR_ADMIN_EMAIL (default
# root@localhost), SR_NETWORK (default serviceradar_serviceradar-net) and
# SR_TOOLS_IMAGE (default the running stack's tools image).
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

# Sets provisioned to a new trapd package that is ready, with its material in work/<id>.
# It is created over rpc because Compose configures no onboarding signing key, which
# POST /api/admin/collectors needs for the enrollment token.
provision() {
  local name="$1" id status body=""
  id="$(rpc "
    actor = ServiceRadar.Actors.SystemActor.system(:revocation_check)
    package =
      ServiceRadar.Edge.CollectorPackage
      |> Ash.Changeset.for_create(:create, %{collector_type: :trapd, site: \"revocation-check\", hostname: \"${name}.example.com\"}, actor: actor)
      |> Ash.create!()
    IO.puts(package.id)")"
  [[ "${id}" =~ ^[0-9a-f-]{36}$ ]] || fail "create package answered: ${id}"
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
  rpc "
    actor = ServiceRadar.Actors.SystemActor.system(:revocation_check)
    package =
      ServiceRadar.Edge.CollectorPackage
      |> Ash.get!(\"${id}\", actor: actor)
      |> Ash.load!([:nats_creds_ciphertext, :tls_key_pem_ciphertext], actor: actor)
    IO.puts(Jason.encode!(%{creds: package.nats_creds_ciphertext, cert: package.tls_cert_pem, key: package.tls_key_pem_ciphertext, ca: package.ca_chain_pem}))" \
    >"${work}/${id}/material.json"
  local field file
  for field in creds:nats.creds cert:collector.pem key:collector-key.pem ca:ca-chain.pem; do
    file="${work}/${id}/${field#*:}"
    jq -er ".${field%%:*}" "${work}/${id}/material.json" >"${file}" || fail "package ${name} has no ${field%%:*}"
    chmod 0644 "${file}"
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
