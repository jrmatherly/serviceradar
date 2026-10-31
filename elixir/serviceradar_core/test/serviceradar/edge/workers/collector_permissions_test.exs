defmodule ServiceRadar.Edge.Workers.CollectorPermissionsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Edge.NatsLeafCredentials
  alias ServiceRadar.Edge.Workers.ProvisionCollectorWorker
  alias ServiceRadar.NATS.AgentFlowCollectorPermissions

  # The subject each collector binary publishes, matching its bundle config.
  @expected %{
    flowgger: ["logs.syslog"],
    trapd: ["logs.snmp"],
    otel: ["otel.traces.>", "otel.metrics.>", "logs.otel"],
    netflow: ["flows.raw.netflow"],
    sflow: ["flows.raw.sflow"],
    falcosidekick: ["falco.logs"]
  }

  test "every collector type gets exactly its subjects" do
    for {type, publish} <- @expected do
      assert ProvisionCollectorWorker.collector_permissions(type) == %{
               publish_allow: publish,
               subscribe_allow: ["_INBOX.>"]
             }
    end
  end

  test "matches the fixture the Go tests mint and validate" do
    {:ok, agent} = AgentFlowCollectorPermissions.permissions("agent-42")

    current =
      @expected
      |> Map.new(fn {type, _} -> {type, ProvisionCollectorWorker.collector_permissions(type)} end)
      |> Map.merge(%{agent_flow_collector: agent, leaf: NatsLeafCredentials.leaf_permissions()})

    fixture =
      "../../../../../../go/pkg/cli/testdata/nats-permissions.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert current |> Jason.encode!() |> Jason.decode!() == fixture
  end

  test "no edge collector holds any stream API" do
    for type <- Map.keys(@expected),
        subject <- ProvisionCollectorWorker.collector_permissions(type).publish_allow do
      refute String.starts_with?(subject, "$")
    end
  end

  test "retries outlast a gateway restart, as the leaf worker's do" do
    job = ProvisionCollectorWorker.new(%{"package_id" => "invented"})
    assert job.changes.max_attempts == 10
  end

  describe "failure_message/1" do
    test "a datasvc outage says so instead of an internal atom" do
      assert ProvisionCollectorWorker.failure_message(:not_connected) =~ "datasvc"
    end

    test "each retryable error names its cause" do
      assert ProvisionCollectorWorker.failure_message({:grpc_error, 14, "refused"}) == "refused"

      assert ProvisionCollectorWorker.failure_message(:gateway_unavailable) =~
               "No agent-gateway is reachable"

      assert ProvisionCollectorWorker.failure_message(
               {:collector_certificate_issue_failed, :ca_not_available}
             ) =~
               "ca_not_available"

      assert ProvisionCollectorWorker.failure_message({:connection_failed, :econnrefused}) =~
               "econnrefused"
    end
  end

  describe "require_flow_storage/1" do
    setup do
      prior = Application.get_env(:serviceradar_core, StarRocks)
      on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prior) end)
      :ok
    end

    test "flow collectors need StarRocks, which holds all flow data" do
      Application.put_env(:serviceradar_core, StarRocks, enabled: false, cutover_datasets: [])

      assert ProvisionCollectorWorker.require_flow_storage(:netflow) ==
               {:error, :starrocks_required}

      assert ProvisionCollectorWorker.require_flow_storage(:sflow) ==
               {:error, :starrocks_required}

      Application.put_env(:serviceradar_core, StarRocks,
        enabled: true,
        cutover_datasets: [:flows]
      )

      assert ProvisionCollectorWorker.require_flow_storage(:netflow) == :ok
      assert ProvisionCollectorWorker.require_flow_storage(:sflow) == :ok
    end

    test "other collectors store through CNPG and do not need it" do
      Application.put_env(:serviceradar_core, StarRocks, enabled: false, cutover_datasets: [])

      for type <- [:flowgger, :trapd, :otel, :falcosidekick] do
        assert ProvisionCollectorWorker.require_flow_storage(type) == :ok
      end
    end
  end

  test "covers every collector type a package can have" do
    types =
      ServiceRadar.Edge.CollectorPackage
      |> Ash.Resource.Info.attribute(:collector_type)
      |> Map.fetch!(:constraints)
      |> Keyword.fetch!(:one_of)

    assert Enum.sort(types) == Enum.sort(Map.keys(@expected))
  end
end
