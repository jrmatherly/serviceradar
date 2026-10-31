defmodule ServiceRadarWebNGWeb.Admin.CollectorLiveCreateTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.Admin.CollectorLive.Index

  @moduletag :db_free

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :onboarding_token_private_key)
    Application.delete_env(:serviceradar_web_ng, :onboarding_token_private_key)

    on_exit(fn ->
      if previous, do: Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, previous)
    end)
  end

  test "a missing signing key shows an error and creates nothing" do
    assert {:noreply, socket} =
             Index.handle_event("create_package", %{"collector_type" => "flowgger"}, socket())

    assert socket.assigns.flash["error"] =~ "signing key"
    refute Map.has_key?(socket.assigns, :created_package)
  end

  defp socket do
    %Socket{assigns: %{__changed__: %{}, flash: %{}, collectors_enabled: true, current_scope: nil}}
  end
end
