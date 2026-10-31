defmodule ServiceRadar.Edge.Workers.ProvisionCollectorWorker do
  @moduledoc """
  Oban worker for provisioning NATS credentials and certificates for collector packages.

  - The worker generates NATS user credentials via datasvc gRPC
  - It issues the collector's mTLS certificate from the agent-gateway CA via
    `ServiceRadar.Edge.CollectorCertificateIssuer`. Falcosidekick is exempt: it
    runs in the cluster and mounts the `serviceradar-runtime-certs` secret.

  ## Retries

  The job runs up to 10 times with exponential backoff, about 19 minutes in all,
  which covers a gateway or datasvc that is restarting. If the last attempt
  fails, including by raising, the collector package status is set to `:failed`.
  datasvc answering `INVALID_ARGUMENT` or `FAILED_PRECONDITION` fails it at once,
  since those describe the request or datasvc's configuration and no retry helps.

  ## Usage

      # Enqueue provisioning for a collector package
      {:ok, _job} = ProvisionCollectorWorker.enqueue(package_id)
  """

  use Oban.Worker,
    queue: :nats_accounts,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:package_id]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Edge.CollectorCertificateIssuer
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.NATS.AccountClient
  alias ServiceRadar.Oban.Router
  alias ServiceRadar.Repo

  require Ash.Expr
  require Ash.Query
  require Logger

  @unretryable_grpc_statuses [GRPC.Status.invalid_argument(), GRPC.Status.failed_precondition()]

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
  def perform(%Oban.Job{} = job), do: perform(job, [])

  @doc """
  `perform/1` with an injectable `:certificate_issuer`, a module exporting
  `issue/1` (default `ServiceRadar.Edge.CollectorCertificateIssuer`).
  """
  def perform(
        %Oban.Job{args: %{"package_id" => package_id}, attempt: attempt, max_attempts: max},
        opts
      ) do
    certificate_issuer = Keyword.get(opts, :certificate_issuer, CollectorCertificateIssuer)

    Logger.info(
      "Provisioning credentials for collector package #{package_id} (attempt #{attempt}/#{max})"
    )

    with {:ok, package} <- get_package(package_id),
         :ok <- validate_package_status(package),
         {:ok, package} <- mark_provisioning(package),
         :ok <- require_flow_storage(package.collector_type),
         {:ok, account_name} <- AccountClient.account_name(),
         {:ok, user_creds} <- generate_user_credentials(account_name, package),
         {:ok, tls} <- issue_certificate(certificate_issuer, package),
         {:ok, _package} <- persist_credentials(package, user_creds, tls) do
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

      {:error, {:grpc_error, status, message} = reason}
      when status in @unretryable_grpc_statuses ->
        Logger.error("datasvc refused credentials for package #{package_id}: #{message}")
        mark_failed(package_id, message)
        {:discard, reason}

      {:error, reason} = error ->
        message = failure_message(reason)

        Logger.warning(
          "Provisioning collector package #{package_id} failed (attempt #{attempt}/#{max}): #{message}"
        )

        if attempt >= max do
          mark_failed(package_id, message)
        end

        error
    end
  catch
    # Oban counts a raise or exit as a failed attempt but it skips the branches
    # above, so without this the last one leaves the package in :provisioning.
    kind, reason ->
      if attempt >= max do
        mark_failed(package_id, Exception.format_banner(kind, reason, __STACKTRACE__))
      end

      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc false
  # What a package shows the operator when a retryable error used its last attempt.
  @spec failure_message(term()) :: String.t()
  def failure_message(:not_connected), do: "datasvc is not reachable to mint NATS credentials"
  def failure_message({:grpc_error, _status, message}), do: message

  def failure_message(:gateway_unavailable),
    do: "No agent-gateway is reachable to issue the collector's TLS certificate"

  def failure_message({:collector_certificate_issue_failed, reason}),
    do: "The agent-gateway could not issue the collector's TLS certificate: #{inspect(reason)}"

  def failure_message(reason), do: inspect(reason)

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
  # subjects, and makes no stream API call: behind a leaf the leaf's own JetStream
  # answers one. The stream's trusted owner (the otel log-collector or core's
  # EventWriter) creates it and captures these subjects, so no edge host can
  # rewrite, purge or delete a shared stream.
  @spec collector_permissions(atom()) :: %{
          publish_allow: [String.t()],
          subscribe_allow: [String.t()]
        }
  def collector_permissions(:flowgger), do: publisher(["logs.syslog"])
  def collector_permissions(:trapd), do: publisher(["logs.snmp"])

  def collector_permissions(:otel),
    do: publisher(["otel.traces.>", "otel.metrics.>", "logs.otel"])

  def collector_permissions(:netflow), do: publisher(["flows.raw.netflow"])
  def collector_permissions(:sflow), do: publisher(["flows.raw.sflow"])

  # Falcosidekick publishes plain NATS messages. The events stream captures only
  # falco.logs (EventWriter FALCO entry).
  def collector_permissions(:falcosidekick), do: publisher(["falco.logs"])

  defp publisher(subjects), do: %{publish_allow: subjects, subscribe_allow: ["_INBOX.>"]}

  # Issued last so a retry after a datasvc failure leaves no orphan certificate.
  defp issue_certificate(_issuer, %{collector_type: :falcosidekick}), do: {:ok, %{}}
  defp issue_certificate(issuer, package), do: issuer.issue(package)

  defp persist_credentials(package, user_creds, tls) do
    Repo.transaction(fn ->
      with :ok <- require_provisioning(package.id),
           {:ok, credential} <- create_credential_record(package, user_creds),
           {:ok, ready} <-
             mark_ready(package, credential.id, user_creds.creds_file_content, tls) do
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

  defp mark_ready(package, credential_id, nats_creds_content, tls) do
    actor = SystemActor.system(:provision_collector)

    with {:ok, current} <- get_package(package.id) do
      if current.status == :provisioning do
        current
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:nats_credential_id, credential_id)
        |> Ash.Changeset.set_argument(:nats_creds_content, nats_creds_content)
        |> Ash.Changeset.for_update(:ready, tls, actor: actor)
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
