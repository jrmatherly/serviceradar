defmodule ServiceRadar.Edge.Workers.ReapplyNatsRevocationsWorker do
  @moduledoc """
  Re-applies every `:revoked` `NatsCredential` to the NATS hub.

  The hub keeps revocations only in the account JWT on its `nats-data` volume. When
  that volume is recreated while `nats-creds` stays, `nats-config-init` seeds the JWT
  with none, so revoked credentials connect again while CNPG still says `:revoked`.
  CNPG is the source of truth, and this job restores the hub from it.

  datasvc pushes nothing when it already holds every key, so a healthy run changes
  nothing. A failure is logged at error and left to Oban, because it means revoked
  credentials may be live. Revoking needs an account name, so revoked keys with no
  account name left mean a misconfigured deployment: that warns, since a retry cannot
  fix it.
  """

  use Oban.Worker,
    queue: :nats_accounts,
    max_attempts: 3,
    # Not :executing: Lifeline takes hours to free a job whose node died, and until
    # then that row would stop every run while revoked credentials may be live.
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.NATS.AccountClient

  require Logger

  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:nats_revocation_replay)
    client = Application.get_env(:serviceradar, :nats_account_client, AccountClient)

    NatsCredential
    |> Ash.Query.for_read(:revoked, %{}, actor: actor)
    |> Ash.stream!(actor: actor, batch_size: @batch_size)
    |> Stream.map(& &1.user_public_key)
    |> reapply(client)
  end

  @doc false
  def reapply(keys, client) do
    keys
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, applied} ->
      case client.revoke_users_on_core(batch) do
        {:ok, %{newly_revoked: count}} -> {:cont, {:ok, applied + count}}
        {:error, reason} -> {:halt, {:error, reason, applied}}
      end
    end)
    |> report()
  end

  defp report({:error, :nats_not_configured, _applied}) do
    Logger.warning("Revoked NATS credentials exist, but no node has a NATS account name")
    :ok
  end

  defp report({:error, reason, applied}) do
    Logger.error(
      "Could not re-apply NATS revocations, so revoked credentials may be live " <>
        "(#{applied} applied before the failure): #{inspect(reason)}"
    )

    {:error, reason}
  end

  defp report({:ok, 0}), do: :ok

  defp report({:ok, applied}) do
    Logger.warning("NATS hub had lost #{applied} revocations, and they are re-applied")
    :ok
  end
end
