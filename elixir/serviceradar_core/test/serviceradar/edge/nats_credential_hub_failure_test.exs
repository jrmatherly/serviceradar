defmodule ServiceRadar.Edge.NatsCredentialHubFailureTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.NatsCredential

  defmodule HubStub do
    @moduledoc false
    def revoke_users_on_core(_keys), do: Process.get(:hub_revoke_result)
  end

  setup do
    prior = Application.get_env(:serviceradar, :nats_account_client)
    Application.put_env(:serviceradar, :nats_account_client, HubStub)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:serviceradar, :nats_account_client, prior),
        else: Application.delete_env(:serviceradar, :nats_account_client)
    end)
  end

  defp failure_message(reason) do
    Process.put(:hub_revoke_result, {:error, reason})

    %NatsCredential{user_public_key: "UINVENTED"}
    |> Ash.Changeset.new()
    |> NatsCredential.revoke_on_hub()
    |> Map.fetch!(:errors)
    |> Enum.map_join(" ", &Exception.message/1)
  end

  test "unreachable nodes say to retry and name the nodes" do
    message = failure_message({:nodes_unreachable, [:core@invented]})

    assert message =~ "did not revoke"
    assert message =~ "core@invented"
    assert message =~ "try again"
  end

  test "any other reason is reported as it came" do
    assert failure_message(:nats_not_configured) =~ "nats_not_configured"
  end
end
