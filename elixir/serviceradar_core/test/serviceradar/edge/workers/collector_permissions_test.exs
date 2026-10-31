defmodule ServiceRadar.Edge.Workers.CollectorPermissionsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.Workers.ProvisionCollectorWorker

  # The subject each collector binary publishes, matching its bundle config.
  @expected %{
    flowgger: ["logs.syslog", "$JS.API.STREAM.INFO.events"],
    trapd: ["logs.snmp", "$JS.API.STREAM.INFO.events"],
    otel: ["otel.traces.>", "otel.metrics.>", "logs.otel", "$JS.API.STREAM.INFO.events"],
    netflow: ["flows.raw.netflow"],
    sflow: ["flows.raw.sflow"],
    falcosidekick: ["falco.logs"]
  }

  test "every collector type gets exactly its subjects and stream calls" do
    for {type, publish} <- @expected do
      assert ProvisionCollectorWorker.collector_permissions(type) == %{
               publish_allow: publish,
               subscribe_allow: ["_INBOX.>"]
             }
    end
  end

  test "no edge collector may change or delete a stream" do
    for type <- Map.keys(@expected),
        subject <- ProvisionCollectorWorker.collector_permissions(type).publish_allow,
        String.starts_with?(subject, "$") do
      assert subject =~ ~r/^\$JS\.API\.STREAM\.INFO\.[A-Za-z0-9_-]+$/
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
