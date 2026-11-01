defmodule ServiceRadar.Edge.Workers.ReapplyNatsRevocationsWorkerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.Workers.ReapplyNatsRevocationsWorker

  @moduletag :database

  defmodule HubStub do
    @moduledoc false
    def revoke_users_on_core(keys) do
      send(self(), {:hub_revoke, keys})
      {:ok, %{account_public_key: "AINVENTED", newly_revoked: 0}}
    end
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    prior = Application.get_env(:serviceradar, :nats_account_client)
    Application.put_env(:serviceradar, :nats_account_client, HubStub)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:serviceradar, :nats_account_client, prior),
        else: Application.delete_env(:serviceradar, :nats_account_client)
    end)

    {:ok, actor: SystemActor.system(:reapply_revocations_test)}
  end

  defp credential(actor) do
    suffix = System.unique_integer([:positive])

    NatsCredential
    |> Ash.Changeset.for_create(
      :create,
      %{user_name: "invented-#{suffix}", user_public_key: "UINVENTED#{suffix}"},
      actor: actor
    )
    |> Ash.create!()
  end

  defp revoke!(credential, actor) do
    credential
    |> Ash.Changeset.for_update(:revoke, %{reason: "invented"}, actor: actor)
    |> Ash.update!()
  end

  defp keys_sent do
    receive do
      {:hub_revoke, keys} -> keys ++ keys_sent()
    after
      0 -> []
    end
  end

  test "sends revoked keys and not active ones", %{actor: actor} do
    revoked = actor |> credential() |> revoke!(actor)
    active = credential(actor)

    # Clears the mailbox of the revoke! call above, which also used the stub.
    keys_sent()

    assert :ok = ReapplyNatsRevocationsWorker.perform(%Oban.Job{})

    sent = keys_sent()
    assert revoked.user_public_key in sent
    refute active.user_public_key in sent
  end

  test "the read reaches keys past the first page", %{actor: actor} do
    keys = for _ <- 1..3, do: (actor |> credential() |> revoke!(actor)).user_public_key

    read =
      NatsCredential
      |> Ash.Query.for_read(:revoked, %{}, actor: actor)
      |> Ash.stream!(actor: actor, batch_size: 2)
      |> Enum.map(& &1.user_public_key)

    assert keys -- read == []
    assert read == Enum.uniq(read)
  end

  test "the read returns the key and no other field of the row", %{actor: actor} do
    actor |> credential() |> revoke!(actor)

    [row] =
      NatsCredential
      |> Ash.Query.for_read(:revoked, %{}, actor: actor)
      |> Ash.stream!(actor: actor, batch_size: 1)
      |> Enum.take(1)

    assert is_binary(row.user_public_key)
    assert %Ash.NotLoaded{} = row.user_name
  end
end
