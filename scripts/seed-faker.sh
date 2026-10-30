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
# Core admits at most 50 chunks of one sync run (64 chunks, 64 MiB over all runs;
# compiled defaults) and rejects the rest. A rejected chunk also marks the run
# incomplete, so its Armis source snapshot is never activated, though devices
# from admitted chunks still land. The agent re-streams the whole fleet in the
# same order on every run, so a dropped tail stays dropped. The agent splits a
# 1000-device page into two chunks under its 1 MiB default, so the seed raises
# that limit to keep one page per chunk: the 50 data chunks fit and only the
# run's final marker, the 51st message, is rejected, which is why every seeded
# run is marked incomplete. The seed also sets the source's discovery interval,
# the one the agent schedules runs by, to two hours so a run is not re-streamed
# into a queue still draining it.
set -euo pipefail

cd "$(dirname "$0")/.."

project="${COMPOSE_PROJECT_NAME:-serviceradar}"
# shortcut: 50 pages of 1000 devices held 58 MB (measured) of core's 64 MiB
# in-flight budget, so fleets above ~50,000 lose their tail. Core's rejection
# never reaches the agent (the gateway forwards sync results without waiting
# for core); raise the default once that path acks and the agent retries.
device_count="${SEED_DEVICE_COUNT:-50000}"
source_name="${SEED_SOURCE_NAME:-faker-seed}"
partition="${SEED_PARTITION:-faker-seed}"
# The 90 min default assumes ~600 devices a minute; a laptop did 50,000 in 23 min.
wait_seconds="${SEED_WAIT_SECONDS:-5400}"
faker_port="${SEED_FAKER_PORT:-8081}"
sync_interval=7200
work_dir="tmp/seed-faker"
volume="${SERVICERADAR_VOLUME_PREFIX:-$project}_seed-faker-data"

# Both names are spliced into SQL and Elixir strings below.
if ! [[ "$source_name" =~ ^[A-Za-z0-9_-]+$ && "$partition" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "SEED_SOURCE_NAME and SEED_PARTITION must match [A-Za-z0-9_-]+" >&2
  exit 2
fi

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
unpurged_sql="select count(*) from platform.ocsf_devices where partition = '$partition' and identity_purged_at is null"

count_rows() {
  core_value "IO.puts(hd(hd(ServiceRadar.Repo.query!(\"$1\").rows)))" | grep -E '^[0-9]+$' || true
}

count_devices() { count_rows "$count_sql"; }

# poll <timeout-seconds> <interval-seconds> <failure-message> <predicate...>
# A predicate returns 0 when done, 1 to keep polling, 2 to stop at once.
poll() {
  local deadline=$((SECONDS + $1)) interval="$2" message="$3" rc
  shift 3
  while :; do
    "$@" && return
    rc=$?
    (( rc == 2 )) && return 1
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
  local count
  count="$(curl -fsS "http://127.0.0.1:${faker_port}/debug/armis/ready" 2>/dev/null | jq -r '.data.device_count // empty')" || true
  [[ "$count" == "$device_count" ]] && return 0
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > device_count )); then
    echo "faker holds a dataset of $count devices, not $device_count; run $0 down first" >&2
    return 2
  fi
  return 1
}

core_answers() { core_eval 'IO.puts(:ok)' >/dev/null 2>&1; }

agent_connected() {
  [[ "$(core_value 'ServiceRadar.Infrastructure.Agent.list_connected!(actor: ServiceRadar.Actors.SystemActor.system(:seed_faker)) |> length() |> IO.puts()')" =~ ^[1-9] ]]
}

# An empty answer means core is busy or down and is retried; "unreadable" means
# the queue process is gone or renamed, which no amount of waiting fixes.
ingest_idle() {
  case "$(core_value '
    try do
      s = :sys.get_state(ServiceRadar.Inventory.SyncIngestorQueue, 5000)
      IO.puts(if map_size(s.jobs) == 0 and is_nil(s.active), do: "idle", else: "busy")
    catch
      :exit, _ -> IO.puts("unreadable")
    end
  ')" in
    idle) return 0 ;;
    unreadable) echo "core's sync ingest queue is not readable over rpc" >&2; return 2 ;;
    *) return 1 ;;
  esac
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
# The worker never raises; it counts failures, so the count is checked here.
delete_devices() {
  core_eval "
    actor = ServiceRadar.Actors.SystemActor.system(:seed_faker)
    alias ServiceRadar.Inventory.{Device, DeviceCleanupWorker}
    uids = ServiceRadar.Repo.query!(\"select uid from platform.ocsf_devices where partition = '$partition' and identity_purged_at is null\").rows |> List.flatten()
    stats =
      uids
      |> Enum.chunk_every(1000)
      |> Enum.reduce(%{deleted: 0, errors: 0, skipped: 0}, fn batch, stats ->
        case Device.bulk_soft_delete(batch, \"seed_faker_down\", actor: actor) do
          :ok ->
            {stats, _count} = DeviceCleanupWorker.hard_delete_records(stats, Enum.map(batch, &%{uid: &1}))
            stats

          {:error, error} ->
            IO.puts(\"soft delete failed for a batch of \" <> Integer.to_string(length(batch)) <> \": \" <> inspect(error))
            %{stats | errors: stats.errors + length(batch)}
        end
      end)
    IO.puts(\"purged \" <> inspect(stats) <> \" of \" <> Integer.to_string(length(uids)) <> \" devices in partition $partition\")
    if stats.errors + stats.skipped > 0 or stats.deleted < length(uids) do
      raise \"purge incomplete; rerun $0 down once the cause in core's log is fixed\"
    end
  "
}

case "${1:-up}" in
  up)
    write_work_files
    compose_files+=(-f "$work_dir/faker.yml" -f "$work_dir/agent.yml")
    compose --profile faker up -d --no-deps faker agent
    poll 120 3 "faker did not report $device_count devices within 120s" faker_ready
    echo "faker ready with $device_count devices"
    poll 300 5 "core-elx did not answer rpc within 300s" core_answers
    poll 300 5 "no agent connected to core within 300s" agent_connected
    ensure_source
    echo "waiting up to ${wait_seconds}s for $device_count devices; query: $count_sql"
    poll "$wait_seconds" 30 "timed out waiting for $device_count devices; the agent's sync log is: docker compose -p $project logs agent" seeded
    echo "seeded: $(count_devices) devices (expected $device_count); query: $count_sql"
    ;;
  status)
    count="$(count_devices)"
    if [[ -z "$count" ]]; then
      echo "core-elx did not answer; query: $count_sql" >&2
      exit 1
    fi
    echo "devices in partition $partition: $count; query: $count_sql"
    ;;
  down)
    poll 300 5 "core-elx did not answer rpc within 300s" core_answers
    remove_source
    echo "waiting for core to finish the sync batches in flight"
    poll "$wait_seconds" 10 "sync ingest still busy after ${wait_seconds}s; rerun down once it drains" ingest_idle
    delete_devices
    compose --profile faker rm -sf faker
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      docker volume rm "$volume" >/dev/null
    fi
    compose up -d --no-deps agent
    left="$(count_rows "$unpurged_sql")"
    echo "devices left in partition $partition: ${left:-unknown} unpurged, $(count_devices) live; query: $unpurged_sql"
    if [[ "$left" != "0" ]]; then
      echo "partition $partition still has ${left:-an unknown number of} unpurged devices; rerun $0 down" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [up|status|down]" >&2
    exit 2
    ;;
esac
