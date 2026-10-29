#!/usr/bin/env bash
# Seeds the local compose stack with synthetic devices from the faker (an Armis
# API emulator) so god view, maps and the Wasm lanes have data to render.
#
#   scripts/seed-faker.sh up      start faker, create the Armis source, wait for the devices
#   scripts/seed-faker.sh status  print the seeded device count
#   scripts/seed-faker.sh down    delete the source and its devices, stop faker, drop its data
#
# SEED_DEVICE_COUNT (default 50000) sets the fleet size. Re-running `up` reuses the
# faker's persisted dataset and the existing source, so it does not duplicate devices.
#
# Core holds at most 50 chunks of one sync run (64 chunks, 64 MiB over all runs)
# in flight and drops the rest, and the agent re-streams the whole fleet in the
# same order on every run, so a dropped tail stays dropped. The agent splits a
# 1000-device page into two chunks under its 1 MiB default, so the seed raises
# that limit to keep one page per chunk (50 chunks fit) and polls the source
# every two hours so a run is not re-streamed into a queue still draining it.
set -euo pipefail

cd "$(dirname "$0")/.."

project="${COMPOSE_PROJECT_NAME:-serviceradar}"
# shortcut: 50 pages of 1000 devices hold ~58 MB of core's hard 64 MiB in-flight
# budget, so fleets above ~50,000 lose their tail; raise the default once the
# agent retries chunks that core rejects.
device_count="${SEED_DEVICE_COUNT:-50000}"
source_name="${SEED_SOURCE_NAME:-faker-seed}"
partition="${SEED_PARTITION:-faker-seed}"
# Ingest runs at roughly a thousand devices a minute on a laptop.
wait_seconds="${SEED_WAIT_SECONDS:-5400}"
faker_port="${SEED_FAKER_PORT:-8081}"
sync_interval=7200
work_dir="tmp/seed-faker"
volume="${SERVICERADAR_VOLUME_PREFIX:-$project}_seed-faker-data"

compose_files=(-f docker-compose.yml -f docker-compose.dev.yml)
# The published BEAM images are amd64; the overlay keeps them booting under Rosetta.
if [[ "$(uname -s)/$(uname -m)" == "Darwin/arm64" ]]; then
  compose_files+=(-f docker-compose.arm64.yml)
fi

compose() { docker compose -p "$project" "${compose_files[@]}" "$@"; }

core_eval() { compose exec -T core-elx /app/bin/serviceradar_core_elx rpc "$1"; }

# The last line of the rpc output, or nothing while core is down or its
# connection pool is saturated.
core_value() { core_eval "$1" 2>/dev/null | tail -1 | tr -d '[:space:]' || true; }

count_sql="select count(*) from platform.ocsf_devices where partition = '$partition' and deleted_at is null"

count_devices() {
  core_value "IO.puts(hd(hd(ServiceRadar.Repo.query!(\"$count_sql\").rows)))" | grep -E '^[0-9]+$' || true
}

# poll <timeout-seconds> <interval-seconds> <failure-message> <predicate...>
poll() {
  local deadline=$((SECONDS + $1)) interval="$2" message="$3"
  shift 3
  until "$@"; do
    if (( SECONDS >= deadline )); then
      echo "$message" >&2
      return 1
    fi
    sleep "$interval"
  done
}

write_work_files() {
  mkdir -p "$work_dir"
  jq --argjson n "$device_count" '.simulation.total_devices = $n' go/cmd/faker/config.json > "$work_dir/faker.json"
  cat > "$work_dir/faker.yml" <<YAML
services:
  faker:
    volumes:
      - $PWD/$work_dir/faker.json:/etc/serviceradar/faker.json:ro
      - seed-faker-data:/var/lib/serviceradar/faker
volumes:
  seed-faker-data:
    name: "$volume"
YAML
  cat > "$work_dir/agent.yml" <<YAML
services:
  agent:
    environment:
      - SWEEP_RESULTS_MAX_CHUNK_BYTES=4194304
YAML
}

faker_ready() {
  [[ "$(curl -fsS "http://127.0.0.1:${faker_port}/debug/armis/ready" 2>/dev/null | jq -r '.data.device_count // empty')" == "$device_count" ]]
}

agent_connected() {
  [[ "$(core_value 'ServiceRadar.Infrastructure.Agent.list_connected!(actor: ServiceRadar.Actors.SystemActor.system(:seed_faker)) |> length() |> IO.puts()')" =~ ^[1-9] ]]
}

core_answers() { core_eval 'IO.puts(:ok)' >/dev/null 2>&1; }

ingest_idle() {
  [[ "$(core_value '
    s = :sys.get_state(ServiceRadar.Inventory.SyncIngestorQueue)
    IO.puts(if map_size(s.jobs) == 0 and is_nil(s.active), do: "idle", else: "busy")
  ')" == "idle" ]]
}

seeded() {
  local count
  count="$(count_devices)"
  echo "$(date +%H:%M:%S) devices in partition $partition: ${count:-unavailable, core busy}"
  [[ -n "$count" ]] && (( count >= device_count ))
}

find_source_ex="
  actor = ServiceRadar.Actors.SystemActor.system(:seed_faker)
  alias ServiceRadar.Integrations.IntegrationSource
  source = Enum.find(Ash.read!(IntegrationSource, actor: actor), &(&1.name == \"$source_name\"))
"

ensure_source() {
  core_eval "$find_source_ex
    case source do
      nil ->
        [agent | _] = ServiceRadar.Infrastructure.Agent.list_connected!(actor: actor)

        IntegrationSource
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:credentials, %{secret_key: \"seed-faker\", page_size: \"1000\"})
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: \"$source_name\",
            source_type: :armis,
            endpoint: \"http://faker:8080\",
            agent_id: agent.uid,
            partition: \"$partition\",
            poll_interval_seconds: $sync_interval,
            discovery_interval_seconds: $sync_interval,
            page_size: 1000,
            queries: [%{\"label\" => \"all-devices\", \"query\" => \"in:devices\", \"sweep_modes\" => []}]
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

        IO.puts(\"created source $source_name on agent \" <> agent.uid)

      source ->
        source
        |> Ash.Changeset.for_update(
          :update,
          %{poll_interval_seconds: $sync_interval, discovery_interval_seconds: $sync_interval},
          actor: actor
        )
        |> Ash.update!(actor: actor)

        IO.puts(\"source $source_name already exists (\" <> source.id <> \")\")
    end
  " | tail -1
}

remove_source() {
  core_eval "$find_source_ex
    case source do
      nil -> IO.puts(\"no source named $source_name\")
      source ->
        Ash.destroy!(source, action: :delete, actor: actor)
        IO.puts(\"deleted source $source_name\")
    end
  " | tail -1
}

# A raw delete trips RESTRICT foreign keys (fleet ordinals, source observations),
# so the rows go through the product's own path: soft-delete, then
# DeviceCleanupWorker removes the payload and keeps an identity tombstone.
delete_devices() {
  core_eval "
    actor = ServiceRadar.Actors.SystemActor.system(:seed_faker)
    alias ServiceRadar.Inventory.{Device, DeviceCleanupWorker}
    uids = ServiceRadar.Repo.query!(\"select uid from platform.ocsf_devices where partition = '$partition' and identity_purged_at is null\").rows |> List.flatten()
    stats =
      uids
      |> Enum.chunk_every(1000)
      |> Enum.reduce(%{deleted: 0, errors: 0, skipped: 0}, fn batch, stats ->
        :ok = Device.bulk_soft_delete(batch, \"seed_faker_down\", actor: actor)
        {stats, _count} = DeviceCleanupWorker.hard_delete_records(stats, Enum.map(batch, &%{uid: &1}))
        stats
      end)
    IO.puts(\"purged \" <> inspect(stats) <> \" of \" <> Integer.to_string(length(uids)) <> \" devices in partition $partition\")
  " | tail -1
}

case "${1:-up}" in
  up)
    write_work_files
    compose_files+=(-f "$work_dir/faker.yml" -f "$work_dir/agent.yml")
    compose --profile faker up -d --no-deps faker agent
    poll 120 3 "faker did not report $device_count devices within 120s; a dataset of another size persists until $0 down" faker_ready
    echo "faker ready with $device_count devices"
    poll 300 5 "no agent connected to core within 300s" agent_connected
    ensure_source
    echo "waiting up to ${wait_seconds}s for $device_count devices; query: $count_sql"
    poll "$wait_seconds" 30 "timed out waiting for $device_count devices; the agent's sync log is: docker compose -p $project logs agent" seeded
    echo "seeded: $(count_devices) devices (expected $device_count); query: $count_sql"
    ;;
  status)
    echo "devices in partition $partition: $(count_devices); query: $count_sql"
    ;;
  down)
    poll 300 5 "core-elx did not answer rpc within 300s" core_answers
    remove_source
    echo "waiting for core to finish the sync batches in flight"
    poll "$wait_seconds" 10 "sync ingest still busy after ${wait_seconds}s; rerun down once it drains" ingest_idle
    delete_devices
    compose --profile faker rm -sf faker
    docker volume rm "$volume" >/dev/null 2>&1 || true
    compose up -d --no-deps agent
    echo "devices left in partition $partition: $(count_devices); query: $count_sql"
    ;;
  *)
    echo "usage: $0 [up|status|down]" >&2
    exit 2
    ;;
esac
