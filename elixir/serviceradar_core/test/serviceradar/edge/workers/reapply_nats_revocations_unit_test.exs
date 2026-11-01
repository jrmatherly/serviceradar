defmodule ServiceRadar.Edge.Workers.ReapplyNatsRevocationsUnitTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Edge.Workers.ReapplyNatsRevocationsWorker, as: Worker

  defmodule HubStub do
    @moduledoc false
    def revoke_users_on_core(keys) do
      send(self(), {:hub_revoke, keys})
      :hub_results |> Process.get([{:ok, %{newly_revoked: 0}}]) |> next_result()
    end

    defp next_result([result]), do: result

    defp next_result([result | rest]) do
      Process.put(:hub_results, rest)
      result
    end
  end

  defp run(keys, results) do
    Process.put(:hub_results, results)
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:result, Worker.reapply(keys, HubStub)})
      end)

    assert_received {:result, result}
    {result, log}
  end

  test "no revoked credentials makes no call" do
    assert {:ok, ""} = run([], [{:error, :must_not_be_called}])
    refute_received {:hub_revoke, _}
  end

  test "a hub holding every key is quiet" do
    assert {:ok, ""} = run(["UA", "UB"], [{:ok, %{newly_revoked: 0}}])
    assert_received {:hub_revoke, ["UA", "UB"]}
  end

  test "a hub that lost keys is reported as a warning with the count" do
    {result, log} = run(["UA", "UB"], [{:ok, %{newly_revoked: 2}}])

    assert result == :ok
    assert log =~ "[warning]"
    assert log =~ "lost 2 revocations"
  end

  test "revoked keys with no NATS account warn and do not retry" do
    {result, log} = run(["UA"], [{:error, :nats_not_configured}])

    assert result == :ok
    assert log =~ "[warning]"
    assert log =~ "no node has a NATS account name"
  end

  test "any other failure is returned and logged at error" do
    {result, log} = run(["UA"], [{:error, {:grpc_error, "invented outage"}}])

    assert result == {:error, {:grpc_error, "invented outage"}}
    assert log =~ "[error]"
    assert log =~ "may be live"
    assert log =~ "invented outage"
  end

  test "keys travel in bounded batches and counts add up across them" do
    keys = Enum.map(1..501, &"U#{&1}")

    {result, log} = run(keys, [{:ok, %{newly_revoked: 1}}, {:ok, %{newly_revoked: 1}}])

    assert result == :ok
    assert log =~ "lost 2 revocations"
    assert_received {:hub_revoke, first}
    assert_received {:hub_revoke, ["U501"]}
    assert length(first) == 500
  end

  test "a failed batch stops the run and says what came before it" do
    keys = Enum.map(1..1001, &"U#{&1}")

    {result, log} =
      run(keys, [{:ok, %{newly_revoked: 3}}, {:error, :invented_outage}])

    assert result == {:error, :invented_outage}
    assert log =~ "3 applied before the failure"
    assert_received {:hub_revoke, _}
    assert_received {:hub_revoke, _}
    refute_received {:hub_revoke, _}
  end

  test "a job held by a dead node does not block the next run" do
    unique = Worker.new(%{}).changes.unique

    refute :executing in unique.states
    assert :available in unique.states
    assert unique.period == :infinity
  end
end
