defmodule ServiceRadar.Edge.CollectorCertificateIssuer do
  @moduledoc """
  Issues the mTLS certificate a collector package presents to NATS, from the
  agent-gateway CA that the hub's and every leaf's `root.pem` trust.

  The CN is `<component_id>.<partition>.serviceradar`. A leaf server maps that
  CN to the collector's user, and the hub takes the collector's identity from
  its NATS credentials.
  """

  alias ServiceRadar.Edge.GatewayCertificates
  alias ServiceRadar.Edge.NatsLeafCertificateIssuer

  @type material :: %{tls_cert_pem: String.t(), tls_key_pem: String.t(), ca_chain_pem: String.t()}

  @doc """
  Issues the package's certificate. Takes the options of
  `ServiceRadar.Edge.GatewayCertificates.gateway_node/1`, plus `:partition_id`.
  """
  @spec issue(map(), keyword()) :: {:ok, material()} | {:error, term()}
  def issue(package, opts \\ []) do
    partition_id =
      Keyword.get_lazy(opts, :partition_id, &NatsLeafCertificateIssuer.partition_id/0)

    issuer_opts = [
      audit_actor: %{id: "system", email: "collector-provisioner@serviceradar.local"}
    ]

    with {:ok, node} <- GatewayCertificates.gateway_node(opts),
         {:ok, bundle} <-
           GatewayCertificates.issue(
             node,
             component_id(package),
             partition_id,
             :collector,
             issuer_opts,
             opts
           ) do
      {:ok,
       %{
         tls_cert_pem: bundle.certificate_pem,
         tls_key_pem: bundle.private_key_pem,
         ca_chain_pem: bundle.ca_chain_pem
       }}
    else
      {:error, {:issue_failed, reason}} -> {:error, {:collector_certificate_issue_failed, reason}}
      {:error, _reason} = error -> error
    end
  end

  @doc "The certificate's component id. Derived from the package so it needs no storage."
  @spec component_id(map()) :: String.t()
  def component_id(%{id: id, collector_type: type}), do: "#{type}-#{String.replace(id, "-", "")}"
end
