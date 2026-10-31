defmodule ServiceRadar.Edge.Workers.ProvisionCollectorWorkerTest do
  @moduledoc """
  ExUnit coverage for `ProvisionCollectorWorker.perform/2` persistence.

  The datasvc transport is faked at the existing public
  `GRPC.Client.Adapter` contract: the supervised `DataService.Client`
  carries a test-only adapter channel, so the real `AccountClient`
  request building, protobuf encoding and response mapping run
  unchanged. The fake only returns synthetic RPC responses and
  arranges request/release ordering; persisted cleanup is asserted
  against real Ash state.
  """

  use ServiceRadar.DataCase, async: false

  alias GRPC.Client.Stream
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.Workers.ProvisionCollectorWorker
  alias ServiceRadar.Repo

  @moduletag :database

  defmodule FakeDatasvcAdapter do
    @moduledoc false

    @behaviour GRPC.Client.Adapter

    @impl true
    def connect(channel, _opts), do: {:ok, channel}

    @impl true
    def disconnect(channel), do: {:ok, channel}

    @impl true
    def send_request(%Stream{} = stream, contents, _opts) do
      coordinator =
        Application.fetch_env!(:serviceradar_core, :provision_collector_worker_test_coordinator)

      request = Proto.GenerateUserCredentialsRequest.decode(IO.iodata_to_binary(contents))
      send(coordinator, {:datasvc_generate_user_credentials, self(), request})

      receive do
        {:datasvc_release, plan} -> Stream.put_payload(stream, :test_plan, plan)
      after
        15_000 -> Stream.put_payload(stream, :test_plan, {:error, :fake_release_timeout})
      end
    end

    @impl true
    def receive_data(%Stream{payload: %{test_plan: plan}}, _opts) do
      case plan do
        {:respond, response} -> {:ok, decode_response(response)}
        {:error, reason} -> {:error, reason}
      end
    end

    defp decode_response(response) do
      response
      |> Proto.GenerateUserCredentialsResponse.encode()
      |> IO.iodata_to_binary()
      |> Proto.GenerateUserCredentialsResponse.decode()
    end

    @impl true
    def send_headers(stream, _opts), do: stream

    @impl true
    def send_data(stream, _message, _opts), do: stream

    @impl true
    def end_stream(stream), do: stream

    @impl true
    def cancel(_stream), do: :ok
  end

  defmodule IssuingStub do
    @moduledoc false
    def issue(_package) do
      {:ok,
       %{tls_cert_pem: "invented-cert", tls_key_pem: "invented-key", ca_chain_pem: "invented-ca"}}
    end
  end

  defmodule UnavailableStub do
    @moduledoc false
    def issue(_package), do: {:error, :gateway_unavailable}
  end

  defmodule RefusingStub do
    @moduledoc false
    def issue(_package), do: {:error, {:collector_certificate_issue_failed, :ca_not_available}}
  end

  defmodule NotConnectedStub do
    @moduledoc false
    def issue(_package), do: {:error, :not_connected}
  end

  defmodule RaisingStub do
    @moduledoc false
    def issue(_package), do: raise("invented issuer crash")
  end

  defmodule UnexpectedCallStub do
    @moduledoc false
    def issue(package), do: raise("no certificate expected for #{package.collector_type}")
  end

  defmodule HubStub do
    @moduledoc false
    def revoke_users_on_core(keys) do
      send(self(), {:hub_revoke, keys})
      Process.get(:hub_revoke_result, {:ok, %{account_public_key: "invented-account"}})
    end
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    prior_account_name = Application.get_env(:serviceradar, :nats_account_name)

    prior_coordinator =
      Application.get_env(:serviceradar_core, :provision_collector_worker_test_coordinator)

    Application.put_env(:serviceradar, :nats_account_name, "TEST_ACCOUNT")
    Application.put_env(:serviceradar_core, :provision_collector_worker_test_coordinator, self())

    on_exit(fn ->
      restore_env(:serviceradar, :nats_account_name, prior_account_name)

      restore_env(
        :serviceradar_core,
        :provision_collector_worker_test_coordinator,
        prior_coordinator
      )
    end)

    client_started? =
      case start_supervised(
             {Client,
              host: "127.0.0.1",
              port: 1,
              sec_mode: "plaintext",
              connect_timeout_ms: 10,
              reconnect_base_ms: 60_000,
              reconnect_max_ms: 60_000}
           ) do
        {:ok, _pid} -> true
        {:error, {:already_started, _pid}} -> false
      end

    prior_channel =
      if !client_started? do
        Client |> :sys.get_state(15_000) |> Map.take([:channel, :connect_task])
      end

    on_exit(fn ->
      if !client_started? do
        :sys.replace_state(Client, fn state -> Map.merge(state, prior_channel) end, 15_000)
      end
    end)

    :sys.replace_state(
      Client,
      fn state ->
        %{state | channel: %GRPC.Channel{adapter: FakeDatasvcAdapter}, connect_task: nil}
      end,
      15_000
    )

    %{
      actor: SystemActor.system(:provision_collector_worker_test),
      unique_id: :erlang.unique_integer([:positive])
    }
  end

  describe "perform/1 normal provisioning" do
    test "attaches exactly one active credential and stores private contents", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)
      public_key = "U9TESTCOLLECTOR#{u}"
      task = start_perform_task(package.id)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, request}, 10_000

      assert request.account_name == "TEST_ACCOUNT"
      refute Map.has_key?(request, :account_seed)
      assert request.user_name == package.user_name
      assert request.credential_type == :USER_CREDENTIAL_TYPE_COLLECTOR

      assert request.permissions.publish_allow == ["logs.syslog"]

      send(adapter_pid, {:datasvc_release, {:respond, credential_response(public_key, u)}})
      assert :ok = Task.await(task, 30_000)

      ready = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert ready.status == :ready
      assert is_binary(ready.nats_credential_id)

      credential =
        NatsCredential
        |> Ash.Query.for_read(:by_user_name, %{user_name: package.user_name})
        |> Ash.read_one!(actor: actor)

      assert credential.id == ready.nats_credential_id
      assert credential.status == :active
      assert credential.user_public_key == public_key
      assert credential.credential_type == :collector

      assert count_credentials(actor) == 1
      assert stored_creds_ciphertext(package.id)

      assert ready.tls_cert_pem == "invented-cert"
      assert ready.ca_chain_pem == "invented-ca"

      assert {:ok, %{tls_key_pem_ciphertext: "invented-key"}} =
               Ash.load(ready, [:tls_key_pem_ciphertext], actor: actor)
    end
  end

  describe "perform/1 certificate issuance" do
    test "no live gateway is retried, leaves the package provisioning, and stores nothing", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)
      task = start_perform_task(package.id, certificate_issuer: UnavailableStub)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      assert {:error, :gateway_unavailable} = Task.await(task, 30_000)

      stalled = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert stalled.status == :provisioning
      assert is_nil(stalled.error_message)
      assert count_credentials(actor) == 0
      assert stored_creds_ciphertext(package.id) == nil
    end

    test "no live gateway on the last attempt fails the package with a clear message", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)
      task = start_perform_task(package.id, [certificate_issuer: UnavailableStub], 5)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      assert {:error, :gateway_unavailable} = Task.await(task, 30_000)

      failed = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert failed.status == :failed
      assert failed.error_message =~ "No agent-gateway is reachable"
    end

    test "a gateway refusal on the last attempt names the reason", %{actor: actor, unique_id: u} do
      package = create_package!(actor, u)
      task = start_perform_task(package.id, [certificate_issuer: RefusingStub], 5)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      assert {:error, _reason} = Task.await(task, 30_000)

      failed = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert failed.status == :failed
      assert failed.error_message =~ "ca_not_available"
    end

    test "datasvc not connected is retried, then fails the package on the last attempt", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)
      first = start_perform_task(package.id, certificate_issuer: NotConnectedStub)
      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      assert {:error, :not_connected} = Task.await(first, 30_000)
      assert Ash.get!(CollectorPackage, package.id, actor: actor).status == :provisioning

      last = start_perform_task(package.id, [certificate_issuer: NotConnectedStub], 5)
      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      assert {:error, :not_connected} = Task.await(last, 30_000)

      failed = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert failed.status == :failed
      assert failed.error_message =~ "datasvc"
    end

    test "a crash on the last attempt fails the package and still reaches Oban", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)

      task =
        Task.async(fn ->
          assert_raise RuntimeError, "invented issuer crash", fn ->
            ProvisionCollectorWorker.perform(build_job(package.id, 5),
              certificate_issuer: RaisingStub
            )
          end
        end)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      Task.await(task, 30_000)

      failed = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert failed.status == :failed
      assert failed.error_message =~ "invented issuer crash"
    end

    test "a crash before the last attempt leaves the package for the retry", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)

      task =
        Task.async(fn ->
          assert_raise RuntimeError, fn ->
            ProvisionCollectorWorker.perform(build_job(package.id),
              certificate_issuer: RaisingStub
            )
          end
        end)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      Task.await(task, 30_000)
      assert Ash.get!(CollectorPackage, package.id, actor: actor).status == :provisioning
    end

    test "falcosidekick asks for no certificate", %{actor: actor, unique_id: u} do
      package = create_package!(actor, u, :falcosidekick)
      task = start_perform_task(package.id, certificate_issuer: UnexpectedCallStub)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      assert :ok = Task.await(task, 30_000)

      ready = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert ready.status == :ready
      assert is_nil(ready.tls_cert_pem)
    end
  end

  describe "perform/1 for a flow package" do
    test "without StarRocks fails the package and mints nothing", %{actor: actor, unique_id: u} do
      prior = Application.get_env(:serviceradar_core, StarRocks)
      on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prior) end)
      Application.put_env(:serviceradar_core, StarRocks, enabled: false, cutover_datasets: [])

      package = create_package!(actor, u, :netflow)

      assert {:discard, :starrocks_required} =
               ProvisionCollectorWorker.perform(build_job(package.id))

      failed = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert failed.status == :failed
      assert failed.error_message =~ "StarRocks"
      refute_received {:datasvc_generate_user_credentials, _, _}
      assert count_credentials(actor) == 0
    end

    test "with StarRocks provisions like any collector", %{actor: actor, unique_id: u} do
      prior = Application.get_env(:serviceradar_core, StarRocks)
      on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prior) end)

      Application.put_env(:serviceradar_core, StarRocks,
        enabled: true,
        cutover_datasets: [:flows]
      )

      package = create_package!(actor, u, :sflow)
      task = start_perform_task(package.id)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, request}, 10_000
      assert request.permissions.publish_allow == ["flows.raw.sflow"]

      send(
        adapter_pid,
        {:datasvc_release, {:respond, credential_response("U9TESTCOLLECTOR#{u}", u)}}
      )

      assert :ok = Task.await(task, 30_000)
      assert Ash.get!(CollectorPackage, package.id, actor: actor).status == :ready
    end
  end

  describe "perform/1 revoke during generation" do
    test "leaves a terminal package without any new credential or private contents", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)
      public_key = "U9TESTCOLLECTOR#{u}"
      task = start_perform_task(package.id)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      revoked =
        package
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:reason, "revoked during provisioning")
        |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
        |> Ash.update!()

      assert revoked.status == :revoked

      send(adapter_pid, {:datasvc_release, {:respond, credential_response(public_key, u)}})
      assert :ok = Task.await(task, 30_000)

      terminal = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert terminal.status == :revoked
      assert is_nil(terminal.nats_credential_id)

      assert {:ok, nil} =
               NatsCredential
               |> Ash.Query.for_read(:by_user_name, %{user_name: package.user_name})
               |> Ash.read_one(actor: actor)

      assert count_credentials(actor) == 0
      assert stored_creds_ciphertext(package.id) == nil
    end
  end

  describe "revoking a provisioned package" do
    setup do
      prior_client = Application.get_env(:serviceradar, :nats_account_client)
      Application.put_env(:serviceradar, :nats_account_client, HubStub)
      on_exit(fn -> restore_env(:serviceradar, :nats_account_client, prior_client) end)

      actor = SystemActor.system(:provision_collector_worker_test)
      unique_id = System.unique_integer([:positive])
      key = "U" <> String.pad_leading("#{unique_id}", 55, "A")

      credential =
        NatsCredential
        |> Ash.Changeset.for_create(
          :create,
          %{user_name: "collector-#{unique_id}", user_public_key: key},
          actor: actor
        )
        |> Ash.create!()

      package =
        actor
        |> create_package!(unique_id)
        |> Ash.Changeset.for_update(:provision, %{}, actor: actor)
        |> Ash.update!()
        |> Ash.Changeset.for_update(
          :ready,
          %{nats_credential_id: credential.id, nats_creds_content: "invented-creds"},
          actor: actor
        )
        |> Ash.update!()

      %{actor: actor, key: key, credential: credential, package: package}
    end

    test "tells the hub, then marks both records revoked", ctx do
      revoked =
        ctx.package
        |> Ash.Changeset.for_update(:revoke, %{reason: "invented reason"}, actor: ctx.actor)
        |> Ash.update!()

      assert revoked.status == :revoked
      assert_received {:hub_revoke, [key]}
      assert key == ctx.key
      assert Ash.get!(NatsCredential, ctx.credential.id, actor: ctx.actor).status == :revoked
    end

    test "a hub refusal leaves both records active and the error visible", ctx do
      Process.put(:hub_revoke_result, {:error, {:grpc_error, "invented outage"}})

      assert {:error, error} =
               ctx.package
               |> Ash.Changeset.for_update(:revoke, %{}, actor: ctx.actor)
               |> Ash.update()

      assert Exception.message(error) =~ "invented outage"
      assert Ash.get!(CollectorPackage, ctx.package.id, actor: ctx.actor).status == :ready
      assert Ash.get!(NatsCredential, ctx.credential.id, actor: ctx.actor).status == :active
    end

    test "a credential already revoked does not block the package", ctx do
      ctx.credential
      |> Ash.Changeset.for_update(:revoke, %{}, actor: ctx.actor)
      |> Ash.update!()

      assert_received {:hub_revoke, _keys}

      revoked =
        ctx.package
        |> Ash.Changeset.for_update(:revoke, %{}, actor: ctx.actor)
        |> Ash.update!()

      assert revoked.status == :revoked
      refute_received {:hub_revoke, _keys}
    end

    test "a deployment with no NATS account refuses instead of pretending", ctx do
      Process.put(:hub_revoke_result, {:error, :nats_not_configured})

      assert {:error, error} =
               ctx.credential
               |> Ash.Changeset.for_update(:revoke, %{}, actor: ctx.actor)
               |> Ash.update()

      assert Exception.message(error) =~ "nats_not_configured"
      assert Ash.get!(NatsCredential, ctx.credential.id, actor: ctx.actor).status == :active
    end
  end

  describe "perform/1 malformed datasvc response" do
    test "rolls back the credential write instead of attaching", %{actor: actor, unique_id: u} do
      package = create_package!(actor, u)
      public_key = "U9TESTCOLLECTOR#{u}"
      task = start_perform_task(package.id)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      malformed = %{credential_response(public_key, u) | creds_file_content: ""}
      send(adapter_pid, {:datasvc_release, {:respond, malformed}})
      assert {:error, _reason} = Task.await(task, 30_000)

      stalled = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert stalled.status == :provisioning
      assert is_nil(stalled.nats_credential_id)

      assert {:ok, nil} =
               NatsCredential
               |> Ash.Query.for_read(:by_user_name, %{user_name: package.user_name})
               |> Ash.read_one(actor: actor)

      assert count_credentials(actor) == 0
      assert stored_creds_ciphertext(package.id) == nil
    end
  end

  defp start_perform_task(package_id, opts \\ [certificate_issuer: IssuingStub], attempt \\ 1) do
    task =
      Task.async(fn ->
        receive do
          :go -> :ok
        after
          10_000 -> exit(:no_go)
        end

        ProvisionCollectorWorker.perform(build_job(package_id, attempt), opts)
      end)

    # Serial tests run under a shared sandbox owner (DataCase, async: false), so every
    # process already uses the test's connection and Sandbox.allow/3 reports :not_found.
    # Only async (unshared) owners need DataCase.allow_sandbox/1 for test-owned children.
    send(task.pid, :go)
    task
  end

  defp build_job(package_id, attempt \\ 1) do
    %Oban.Job{
      args: %{"package_id" => package_id},
      attempt: attempt,
      max_attempts: 5
    }
  end

  defp create_package!(actor, unique_id, collector_type \\ :flowgger) do
    CollectorPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        collector_type: collector_type,
        site: "collector-race-#{unique_id}",
        hostname: "collector-#{unique_id}.example.com"
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp credential_response(public_key, unique_id) do
    %Proto.GenerateUserCredentialsResponse{
      user_public_key: public_key,
      user_jwt: "test-user-jwt-#{unique_id}",
      creds_file_content:
        "-----BEGIN NATS USER JWT-----\ntest-user-jwt-#{unique_id}\n------END NATS USER JWT------",
      expires_at_unix: 0
    }
  end

  defp count_credentials(actor) do
    NatsCredential |> Ash.Query.for_read(:read) |> Ash.read!(actor: actor) |> length()
  end

  defp stored_creds_ciphertext(package_id) do
    {:ok, uuid_bin} = Ecto.UUID.dump(package_id)

    %{rows: [[ciphertext]]} =
      Repo.query!(
        "SELECT encrypted_nats_creds_ciphertext FROM platform.collector_packages WHERE id = $1",
        [uuid_bin]
      )

    ciphertext
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
