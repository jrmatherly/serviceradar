defmodule ServiceRadar.Edge.NatsLeafCredentials do
  @moduledoc """
  Mints NATS user credentials for an edge-site leaf server.

  The hub authenticates leaf servers by mTLS (see
  `ServiceRadar.Edge.NatsLeafCertificateIssuer`), so credentials are optional.
  When this deployment has a NATS account configured (`:nats_account_name`, the
  same setting `ProvisionCollectorWorker` uses), a leaf-scoped user is minted
  through `ServiceRadar.NATS.AccountClient` and recorded as a `NatsCredential`.
  Without that configuration this returns `{:ok, nil}` and the bundle ships without
  a creds file. Placeholder credentials are never produced.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.NATS.AccountClient

  # No $JS.API.>: a leaf answers $JS.API from its own JetStream (domain edge), and
  # JetStream publishes cross on their data subject and an inbox reply. Pinned by
  # TestLeafCredsReachHubStreamWithoutJetStreamAPI in go/pkg/cli.
  @leaf_permissions %{
    publish_allow: [
      "logs.>",
      "otel.>",
      "events.>",
      "netflow.>",
      "flows.raw.>",
      "falco.>",
      "$JS.ACK.>",
      "_INBOX.>"
    ],
    subscribe_allow: ["$JS.ACK.>", "_INBOX.>"]
  }

  @doc """
  Returns `{:ok, creds_file_content}`, `{:ok, nil}` when no NATS account is
  configured, or `{:error, reason}` when minting fails.
  """
  @spec mint(map(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def mint(edge_site, opts \\ []) do
    account_client = Keyword.get(opts, :account_client, AccountClient)

    case AccountClient.account_name() do
      {:ok, account_name} ->
        user_name = "leaf-#{edge_site.slug}"

        with {:ok, creds} <-
               account_client.generate_user_credentials(
                 account_name,
                 user_name,
                 :service,
                 permissions: @leaf_permissions
               ),
             {:ok, _credential} <- record_credential(edge_site, user_name, creds) do
          {:ok, creds.creds_file_content}
        end

      {:error, :nats_not_configured} ->
        {:ok, nil}
    end
  end

  @doc false
  def leaf_permissions, do: @leaf_permissions

  defp record_credential(edge_site, user_name, creds) do
    NatsCredential
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_name: user_name,
        credential_type: :service,
        expires_at: creds.expires_at,
        metadata: %{
          purpose: "nats-leaf",
          edge_site_id: edge_site.id,
          edge_site_slug: edge_site.slug
        },
        user_public_key: creds.user_public_key,
        onboarding_package_id: nil
      },
      actor: SystemActor.system(:nats_leaf_credentials)
    )
    |> Ash.create()
  end
end
