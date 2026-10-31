defmodule ServiceRadarWebNGWeb.Admin.CollectorLiveCreateTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadarWebNGWeb.Admin.CollectorLive.Index

  @moduletag :db_free

  defmodule RefusingHub do
    @moduledoc false
    def revoke_users_on_core(_keys), do: {:error, {:grpc_error, "invented outage"}}
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :onboarding_token_private_key)
    Application.delete_env(:serviceradar_web_ng, :onboarding_token_private_key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, previous),
        else: Application.delete_env(:serviceradar_web_ng, :onboarding_token_private_key)
    end)
  end

  test "a missing signing key shows an error and creates nothing" do
    assert {:noreply, socket} =
             Index.handle_event("create_package", %{"collector_type" => "flowgger"}, socket())

    assert socket.assigns.flash["error"] =~ "signing key"
    refute Map.has_key?(socket.assigns, :created_package)
  end

  test "an edge site for falcosidekick shows why it was refused" do
    seed = Base.encode64(:crypto.strong_rand_bytes(32))
    Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, seed)

    params = %{"collector_type" => "falcosidekick", "edge_site_id" => Ecto.UUID.generate()}

    assert {:noreply, socket} = Index.handle_event("create_package", params, socket())

    assert socket.assigns.flash["error"] =~ "edge site"
    refute Map.has_key?(socket.assigns, :created_package)
  end

  describe "a failed revoke" do
    setup do
      prior = Application.get_env(:serviceradar, :nats_account_client)
      Application.put_env(:serviceradar, :nats_account_client, RefusingHub)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:serviceradar, :nats_account_client, prior),
          else: Application.delete_env(:serviceradar, :nats_account_client)
      end)
    end

    test "shows what the hub said" do
      error =
        %NatsCredential{user_public_key: "UINVENTED"}
        |> Ash.Changeset.new()
        |> NatsCredential.revoke_on_hub()
        |> Map.fetch!(:errors)
        |> Ash.Error.to_error_class()

      message = Index.revoke_error_message(error)
      assert message =~ "the NATS hub did not revoke this credential"
      assert message =~ "invented outage"
    end

    test "a reason with no detail keeps the plain message" do
      assert Index.revoke_error_message(:not_found) == "Failed to revoke package"
    end
  end

  defp socket do
    %Socket{assigns: %{__changed__: %{}, flash: %{}, collectors_enabled: true, current_scope: nil}}
  end
end
