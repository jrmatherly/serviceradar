#!/usr/bin/env bash
# Rebuilds the Compose stack from nothing and proves it works, because a container
# reporting "healthy" says nothing about NATS: every service here retries or drops
# quietly when a dependency is unreachable.
#
#   scripts/compose-stack.sh rebuild   destroy this project's volumes, start, verify
#   scripts/compose-stack.sh restart   down and up with volumes kept, verify
#   scripts/compose-stack.sh verify    check the running stack
#
# VERIFY_TIMEOUT (default 300) is how long verify waits for the stack to settle.
set -euo pipefail

cd "$(dirname "$0")/.."

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-serviceradar}"
if [ -z "${COMPOSE_FILE:-}" ]; then
  COMPOSE_FILE=docker-compose.yml
  # Without this overlay the amd64 BEAM images halt at boot on Apple Silicon.
  [ "$(uname -sm)" = "Darwin arm64" ] && COMPOSE_FILE="$COMPOSE_FILE:docker-compose.arm64.yml"
  export COMPOSE_FILE
fi

project="$COMPOSE_PROJECT_NAME"
timeout="${VERIFY_TIMEOUT:-300}"
marker="compose-verify-$(date +%s)"
# network-ingest adds trapd, flow-collector and bmp-collector; coldtier is here only
# so that a teardown also removes it.
profiles=(--profile network-ingest)
teardown_profiles=(--profile network-ingest --profile coldtier)

# Services that must hold a NATS connection. The ingest collectors are checked only
# when running, because their profile is optional.
required_identities=(core datasvc log-collector agent-gateway web-ng)
optional_identities=(trapd flow-collector bmp-collector)
required_streams=(events flows metrics ARANCINI_CAUSAL)
required_graphs=(platform_graph serviceradar serviceradar_topology)

nats_json() {
  docker run --rm --network "${project}_serviceradar-net" curlimages/curl:8.17.0 \
    -fsS "http://nats:8222/$1"
}

# Prints only each credential's JWT line, never the seed under it.
identity_jwts() {
  docker run --rm -v "${project}_nats-creds:/creds:ro" alpine:3 sh -c \
    'for f in /creds/*.creds; do echo "$(basename "$f" .creds) $(sed -n 2p "$f")"; done'
}

core_query() {
  docker exec "${project}-core-elx-mtls" /app/bin/serviceradar_core_elx rpc "
    q = fn sql -> {:ok, r} = ServiceRadar.Repo.query(sql); r.rows end
    IO.puts(\"encoding=\" <> (q.(\"show server_encoding\") |> List.flatten() |> hd()))
    IO.puts(\"graphs=\" <> (q.(\"select name::text from ag_catalog.ag_graph\") |> List.flatten() |> Enum.join(\",\")))
    IO.puts(\"marker=\" <> (q.(\"select count(*) from platform.logs where body like '%$marker%'\") |> List.flatten() |> hd() |> to_string()))
  "
}

check_containers() {
  local rows bad
  rows="$(docker ps -a --filter "label=com.docker.compose.project=$project" \
    --format '{{.Names}}|{{.Status}}')"
  [ -n "$rows" ] || { echo "no containers in project $project"; return; }
  bad="$(grep -E '\|(Exited \([1-9]|Restarting|Created|Dead)|unhealthy|health: starting' <<<"$rows" || true)"
  [ -z "$bad" ] || echo "containers not settled: $(tr '\n' ' ' <<<"$bad")"
  local name restarts
  while IFS='|' read -r name _; do
    restarts="$(docker inspect "$name" --format '{{.RestartCount}}')"
    [ "$restarts" = 0 ] || echo "$name restarted $restarts times"
  done <<<"$rows"
}

# Proves the whole path: collector, stream, EventWriter, table. Sent on every attempt
# because UDP is lost while the collector is still starting.
send_marker() {
  docker run --rm --network "${project}_serviceradar-net" alpine:3 sh -c \
    "echo '<14>1 2026-01-01T00:00:00Z host01.example.com compose-verify - - - $marker' | nc -u -w1 log-collector 514" \
    >/dev/null 2>&1 || true
}

check_database() {
  local out
  send_marker
  if ! out="$(core_query 2>&1)"; then
    echo "core could not query the database: $(tail -1 <<<"$out")"
    return
  fi
  grep -qx 'encoding=UTF8' <<<"$out" || echo "database is not UTF8: $(grep '^encoding=' <<<"$out")"
  local graphs graph
  graphs="$(sed -n 's/^graphs=//p' <<<"$out")"
  for graph in "${required_graphs[@]}"; do
    grep -qE "(^|,)$graph(,|$)" <<<"$graphs" || echo "AGE graph $graph is not registered in ag_catalog"
  done
  grep -qE '^marker=[1-9]' <<<"$out" || echo "a syslog marker did not reach CNPG: collector, NATS or EventWriter is broken"
}

check_nats() {
  local connz jsz jwts wanted id
  connz="$(nats_json 'connz?auth=true&limit=1000')" || { echo "NATS monitoring is unreachable"; return; }
  jsz="$(nats_json 'jsz?accounts=true&streams=true&consumers=true')" || { echo "NATS JetStream report is unreachable"; return; }
  jwts="$(identity_jwts)" || { echo "cannot read the nats-creds volume"; return; }

  wanted="${required_identities[*]}"
  for id in "${optional_identities[@]}"; do
    [ "$(docker ps -q --filter "name=^${project}-${id}-mtls$")" = "" ] || wanted="$wanted $id"
  done

  CONNZ="$connz" JSZ="$jsz" JWTS="$jwts" WANTED="$wanted" STREAMS="${required_streams[*]}" python3 - <<'PY'
import base64, json, os

def claims(token):
    body = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))

keys = {}
for line in os.environ["JWTS"].splitlines():
    name, token = line.split()
    keys[name] = claims(token)["sub"]

connected = {c.get("authorized_user") for c in json.loads(os.environ["CONNZ"])["connections"]}
for name in os.environ["WANTED"].split():
    if name not in keys:
        print(f"no credential issued for {name}")
    elif keys[name] not in connected:
        print(f"{name} holds no NATS connection")

streams = {}
for account in json.loads(os.environ["JSZ"]).get("account_details", []):
    for stream in account.get("stream_detail", []):
        streams[stream["name"]] = stream

for name in os.environ["STREAMS"].split():
    if name not in streams:
        print(f"stream {name} does not exist")
    elif not streams[name].get("consumer_detail"):
        print(f"stream {name} has no consumer, so nothing reads it")
PY
}

# Startup can legitimately see one refused connection, so connection errors count
# only in the recent window. Authorization errors never heal, so they count always.
check_logs() {
  local name always recent
  while read -r name; do
    always="$(docker logs "$name" 2>&1 | grep -cE 'Permissions Violation|Authorization Violation|SQL_ASCII is not supported|does not exist at character' || true)"
    [ "$always" = 0 ] || echo "$name logged $always permission or schema errors"
    recent="$(docker logs --since 60s "$name" 2>&1 | grep -cE 'failed to connect|:not_connected|connection refused' || true)"
    [ "$recent" = 0 ] || echo "$name logged $recent connection errors in the last 60s"
  done < <(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.Names}}')
}

verify() {
  local deadline failures
  deadline=$(($(date +%s) + timeout))
  while :; do
    # A crashed check counts as a failure and says so, rather than ending the script here.
    failures="$(check_containers; check_database; check_nats; check_logs)" \
      || failures="$failures"$'\n'"a verify check crashed"
    if [ -z "$failures" ]; then
      echo "PASS: stack verified"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: stack not healthy after ${timeout}s:" >&2
      sed 's/^/  - /' <<<"$failures" >&2
      return 1
    fi
    sleep 15
  done
}

case "${1:-verify}" in
  rebuild)
    docker compose "${teardown_profiles[@]}" down -v --remove-orphans
    left="$(docker volume ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')"
    [ "$left" = 0 ] || { echo "FAIL: $left volumes survived the teardown" >&2; exit 1; }
    docker compose "${profiles[@]}" up -d
    verify
    ;;
  restart)
    docker compose "${teardown_profiles[@]}" down --remove-orphans
    docker compose "${profiles[@]}" up -d
    verify
    ;;
  verify) verify ;;
  *) echo "usage: $0 rebuild|restart|verify" >&2; exit 2 ;;
esac
