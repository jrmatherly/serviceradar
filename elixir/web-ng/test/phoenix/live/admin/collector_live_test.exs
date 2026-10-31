defmodule ServiceRadarWebNGWeb.Admin.CollectorLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, system_actor: 0]

  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential

  @moduletag :web_ng_shared_fixture_db

  defmodule RefusingHub do
    @moduledoc false
    def revoke_users_on_core(_keys), do: {:error, {:grpc_error, "invented outage"}}
  end

  @private_key "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
  @public_key "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="

  setup %{conn: conn} do
    previous_web_nats_url = Application.get_env(:serviceradar_web_ng, :nats_url)
    previous_core_nats_url = Application.get_env(:serviceradar, :nats_url)
    previous_private_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_private_key)
    previous_public_key = Application.get_env(:serviceradar_web_ng, :onboarding_token_public_key)
    Application.put_env(:serviceradar_web_ng, :nats_url, "tls://serviceradar-nats:4222")
    Application.delete_env(:serviceradar, :nats_url)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, @private_key)
    Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, @public_key)

    on_exit(fn ->
      restore_env(:serviceradar_web_ng, :nats_url, previous_web_nats_url)
      restore_env(:serviceradar, :nats_url, previous_core_nats_url)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_private_key, previous_private_key)
      Application.put_env(:serviceradar_web_ng, :onboarding_token_public_key, previous_public_key)
    end)

    user = admin_user_fixture()

    %{conn: log_in_user(conn, user), user: user}
  end

  describe "nats deployment status" do
    test "reads the web-ng NATS URL instead of spinning on provisioning", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "NATS Ready"
      assert html =~ "tls://serviceradar-nats:4222"
      refute html =~ "Provisioning NATS Account"
      refute html =~ "Please wait while your account is being set up"
    end

    test "says NATS is not configured when no URL is set", %{conn: conn} do
      Application.delete_env(:serviceradar_web_ng, :nats_url)
      Application.delete_env(:serviceradar, :nats_url)

      {:ok, _lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "NATS Not Configured"
      refute html =~ "Provisioning NATS Account"
      refute html =~ "Please wait while your account is being set up"
    end
  end

  describe "falcosidekick creation flow" do
    test "shows bundle deployment instructions instead of generic CLI enrollment", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/collectors")

      lv
      |> element("button", "New Collector")
      |> render_click()

      html =
        lv
        |> form("form[phx-submit='create_package']", %{
          "collector_type" => "falcosidekick",
          "site" => "demo",
          "hostname" => "falco-demo",
          "edge_site_id" => ""
        })
        |> render_submit()

      assert html =~ "Collector Created"
      assert html =~ "Step 1: Download and deploy the bundle"
      assert html =~ "Step 2: Run the bundle command"
      assert html =~ "serviceradar-runtime-certs"
      assert html =~ "http://localhost:4002/api/collectors/"
      assert html =~ "./deploy.sh"

      refute html =~ "sudo apt install serviceradar-falcosidekick"
      refute html =~ "/usr/local/bin/srctl enroll --token"
    end
  end

  describe "host collector creation flow" do
    test "installs the package the collector ships in and shows the download token", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/collectors")

      lv |> element("button", "New Collector") |> render_click()

      html =
        lv
        |> form("form[phx-submit='create_package']", %{"collector_type" => "netflow", "edge_site_id" => ""})
        |> render_submit()

      assert html =~ "sudo apt install serviceradar-flow-collector"
      refute html =~ "serviceradar-netflow"
      assert html =~ "collectorpkg-v2:"
      assert html =~ "SERVICERADAR_NATS_COLLECTOR_URL"
    end
  end

  describe "collector capability gating" do
    test "hides collector creation UI when onboarding is disabled", %{conn: conn} do
      previous_capabilities = Application.get_env(:serviceradar_web_ng, :runtime_capabilities)

      Application.put_env(:serviceradar_web_ng, :runtime_capabilities,
        configured?: true,
        enabled: []
      )

      on_exit(fn ->
        Application.put_env(:serviceradar_web_ng, :runtime_capabilities, previous_capabilities)
      end)

      {:ok, lv, html} = live(conn, ~p"/admin/collectors")

      assert html =~ "Collector onboarding is disabled for this deployment."
      refute html =~ "New Collector"
      # The page keeps its own title; the settings navigation must not offer it.
      assert has_element?(lv, "#settings-view-tree")
      refute has_element?(lv, "#settings-view-tree a[href='/admin/collectors']")
    end
  end

  describe "revoking a package" do
    test "a hub refusal shows the reason and leaves the package ready", %{conn: conn} do
      prior = Application.get_env(:serviceradar, :nats_account_client)
      Application.put_env(:serviceradar, :nats_account_client, RefusingHub)
      on_exit(fn -> restore_env(:serviceradar, :nats_account_client, prior) end)

      package = ready_package!()
      {:ok, lv, _html} = live(conn, ~p"/admin/collectors")

      html = render_click(lv, "revoke_package", %{"id" => package.id})

      assert html =~ "the NATS hub did not revoke this credential"
      assert html =~ "invented outage"
      assert Ash.get!(CollectorPackage, package.id, actor: system_actor()).status == :ready
    end
  end

  defp ready_package! do
    actor = system_actor()
    unique = System.unique_integer([:positive])

    credential =
      NatsCredential
      |> Ash.Changeset.for_create(
        :create,
        %{user_name: "collector-#{unique}", user_public_key: "U" <> String.pad_leading("#{unique}", 55, "A")},
        actor: actor
      )
      |> Ash.create!()

    CollectorPackage
    |> Ash.Changeset.for_create(
      :create,
      %{collector_type: :flowgger, site: "site-#{unique}", hostname: "collector-#{unique}.example.com"},
      actor: actor
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:provision, %{}, actor: actor)
    |> Ash.update!()
    |> Ash.Changeset.for_update(
      :ready,
      %{nats_credential_id: credential.id, nats_creds_content: "invented-creds"},
      actor: actor
    )
    |> Ash.update!()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
