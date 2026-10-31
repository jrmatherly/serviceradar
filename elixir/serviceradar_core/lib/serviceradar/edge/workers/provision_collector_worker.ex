defmodule ServiceRadar.Edge.Workers.ProvisionCollectorWorker do
  @moduledoc """
  Oban worker for provisioning NATS credentials for collector packages.

  In single-deployment mode:
  - NATS account configuration comes from environment variables
  - TLS certificates are handled by external infrastructure (SPIFFE/SPIRE, cert-manager)
  - The worker generates NATS user credentials via datasvc gRPC

  ## Retries

  The job will retry up to 5 times with exponential backoff. If all retries
  fail, the collector package status is set to `:failed`.

  ## Usage

      # Enqueue provisioning for a collector package
      {:ok, _job} = ProvisionCollectorWorker.enqueue(package_id)
  """

  use Oban.Worker,
    queue: :nats_accounts,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:package_id]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.NATS.AccountClient
  alias ServiceRadar.Oban.Router
  alias ServiceRadar.Repo

  require Ash.Expr
  require Ash.Query
  require Logger

  @doc """
  Enqueue a credential provisioning job for a collector package.

  ## Options

    * `:scheduled_at` - Schedule the job for a specific time
    * `:priority` - Job priority (lower = higher priority)

  ## Examples

      {:ok, job} = ProvisionCollectorWorker.enqueue(package_id)
  """
  @spec enqueue(Ecto.UUID.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(package_id, opts \\ []) do
    job_opts =
      []
      |> maybe_add_scheduled_at(opts[:scheduled_at])
      |> maybe_add_priority(opts[:priority])

    %{"package_id" => package_id}
    |> new(job_opts)
    |> Router.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"package_id" => package_id}, attempt: attempt, max_attempts: max}) do
    Logger.info(
      "Provisioning credentials for collector package #{package_id} (attempt #{attempt}/#{max})"
    )

    with {:ok, package} <- get_package(package_id),
         :ok <- validate_package_status(package),
         {:ok, package} <- mark_provisioning(package),
         :ok <- require_flow_storage(package.collector_type),
         {:ok, account_name} <- get_account_name(),
         {:ok, user_creds} <- generate_user_credentials(account_name, package),
         {:ok, _package} <- persist_credentials(package, user_creds) do
      Logger.info("Successfully provisioned credentials for collector package #{package_id}")
      :ok
    else
      {:error, :package_not_found} ->
        Logger.error("Collector package #{package_id} not found, discarding job")
        {:discard, :package_not_found}

      {:error, :package_not_pending} ->
        Logger.info("Collector package #{package_id} not in pending state, skipping")
        :ok

      {:error, :starrocks_required} ->
        Logger.error("StarRocks not enabled for flow collector package #{package_id}")

        mark_failed(
          package_id,
          "NetFlow and sFlow data is stored only in StarRocks, which is not enabled for this deployment"
        )

        {:discard, :starrocks_required}

      {:error, :nats_not_configured} ->
        Logger.error("NATS not configured for package #{package_id}")
        mark_failed(package_id, "NATS account not configured for this deployment")
        {:discard, :nats_not_configured}

      {:error, {:grpc_error, message}} = error ->
        Logger.error("gRPC error provisioning credentials for package #{package_id}: #{message}")

        if attempt >= max do
          mark_failed(package_id, message)
        end

        error

      {:error, :not_connected} = error ->
        Logger.warning("datasvc not connected, will retry for package #{package_id}")
        error

      {:error, reason} = error ->
        Logger.error(
          "Error provisioning credentials for package #{package_id}: #{inspect(reason)}"
        )

        if attempt >= max do
          mark_failed(package_id, inspect(reason))
        end

        error
    end
  end

  @doc false
  # Without StarRocks, EventWriter acknowledges flow batches without storing them,
  # so a flow collector would look healthy while its data is dropped.
  @spec require_flow_storage(atom()) :: :ok | {:error, :starrocks_required}
  def require_flow_storage(type) when type in [:netflow, :sflow] do
    case Readers.backend(:flows) do
      {:error, _reason} = error -> error
      _backend -> :ok
    end
  end

  def require_flow_storage(_type), do: :ok

  # Private helpers

  defp get_package(package_id) do
    actor = SystemActor.system(:provision_collector)

    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, :package_not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_package_status(package) do
    if package.status in [:pending, :provisioning] do
      :ok
    else
      {:error, :package_not_pending}
    end
  end

  defp mark_provisioning(package) do
    with {:ok, current} <- get_package(package.id) do
      cond do
        current.status == :provisioning ->
          {:ok, current}

        current.status == :pending ->
          actor = SystemActor.system(:provision_collector)

          current
          |> Ash.Changeset.for_update(:provision, %{}, actor: actor)
          |> guarded_update([:pending])

        true ->
          {:error, :package_not_pending}
      end
    end
  end

  defp get_account_name do
    case Application.get_env(:serviceradar, :nats_account_name) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :nats_not_configured}
    end
  end

  defp generate_user_credentials(account_name, package) do
    # Build permissions based on collector type
    permissions = collector_permissions(package.collector_type)

    AccountClient.generate_user_credentials(
      account_name,
      package.user_name,
      :collector,
      permissions: permissions
    )
  end

  @doc false
  # Edge credentials leave the cluster, so a collector may publish only its own
  # subjects and read its stream's info. The stream's trusted owner (the otel
  # log-collector or core's EventWriter) creates it and captures these subjects,
  # so no edge host can rewrite, purge or delete a shared stream.
  @spec collector_permissions(atom()) :: %{
          publish_allow: [String.t()],
          subscribe_allow: [String.t()]
        }
  def collector_permissions(:flowgger), do: publisher(["logs.syslog"], ["events"])
  def collector_permissions(:trapd), do: publisher(["logs.snmp"], ["events"])

  def collector_permissions(:otel),
    do: publisher(["otel.traces.>", "otel.metrics.>", "logs.otel"], ["events"])

  # Non-owner flow-collector makes no stream call and goes by the publish result.
  def collector_permissions(:netflow), do: publisher(["flows.raw.netflow"], [])
  def collector_permissions(:sflow), do: publisher(["flows.raw.sflow"], [])

  # Falcosidekick publishes plain NATS messages, so it needs no stream call. The
  # events stream captures only falco.logs (EventWriter FALCO entry).
  def collector_permissions(:falcosidekick), do: publisher(["falco.logs"], [])

  defp publisher(subjects, streams) do
    %{
      publish_allow: subjects ++ Enum.map(streams, &"$JS.API.STREAM.INFO.#{&1}"),
      subscribe_allow: ["_INBOX.>"]
    }
  end

  defp persist_credentials(package, user_creds) do
    Repo.transaction(fn ->
      with :ok <- require_provisioning(package.id),
           {:ok, credential} <- create_credential_record(package, user_creds),
           {:ok, ready} <-
             mark_ready(package, credential.id, user_creds.creds_file_content) do
        ready
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp require_provisioning(package_id) do
    case get_package(package_id) do
      {:ok, %{status: :provisioning}} -> :ok
      {:ok, _package} -> {:error, :package_not_pending}
      {:error, error} -> {:error, error}
    end
  end

  defp create_credential_record(package, user_creds) do
    actor = SystemActor.system(:provision_collector)

    NatsCredential
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:user_public_key, user_creds.user_public_key)
    |> Ash.Changeset.set_argument(:onboarding_package_id, nil)
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_name: package.user_name,
        credential_type: :collector,
        collector_type: package.collector_type,
        expires_at: user_creds.expires_at,
        metadata: %{
          site: package.site,
          hostname: package.hostname
        },
        user_public_key: user_creds.user_public_key,
        onboarding_package_id: nil
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp mark_ready(package, credential_id, nats_creds_content) do
    # TLS certificates are optional here. Bundle downloads that need a key
    # supply it on the :ready action; this worker records the NATS creds.
    actor = SystemActor.system(:provision_collector)

    with {:ok, current} <- get_package(package.id) do
      if current.status == :provisioning do
        current
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:nats_credential_id, credential_id)
        |> Ash.Changeset.set_argument(:nats_creds_content, nats_creds_content)
        |> Ash.Changeset.for_update(:ready, %{}, actor: actor)
        |> guarded_update([:provisioning])
      else
        {:error, :package_not_pending}
      end
    end
  end

  defp mark_failed(package_id, message) do
    case get_package(package_id) do
      {:ok, package} ->
        actor = SystemActor.system(:provision_collector)

        package
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:error_message, message)
        |> Ash.Changeset.for_update(:fail, %{}, actor: actor)
        |> guarded_update([:pending, :provisioning])

      _ ->
        :ok
    end
  end

  defp guarded_update(changeset, statuses) do
    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status in ^statuses))
    |> Ash.update()
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, error} ->
        if stale_record?(error), do: {:error, :package_not_pending}, else: {:error, error}
    end
  end

  defp stale_record?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp stale_record?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &stale_record?/1)

  defp stale_record?(_error), do: false

  defp maybe_add_scheduled_at(opts, nil), do: opts
  defp maybe_add_scheduled_at(opts, %DateTime{} = at), do: Keyword.put(opts, :scheduled_at, at)

  defp maybe_add_priority(opts, nil), do: opts
  defp maybe_add_priority(opts, priority), do: Keyword.put(opts, :priority, priority)
end
