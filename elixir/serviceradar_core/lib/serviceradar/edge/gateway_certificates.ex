defmodule ServiceRadar.Edge.GatewayCertificates do
  @moduledoc """
  Asks a live agent-gateway node to issue a certificate from its CA.

  Core never holds the CA key, so every certificate core needs comes through
  `ServiceRadarAgentGateway.CertIssuer` over ERTS RPC.
  """

  require Logger

  @gateway_cert_issuer ServiceRadarAgentGateway.CertIssuer
  @rpc_timeout 30_000

  @type bundle :: %{
          required(:certificate_pem) => String.t(),
          required(:private_key_pem) => String.t(),
          required(:ca_chain_pem) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Finds an active gateway node.

  Options:
    * `:gateway_node` - skip discovery and use this node
    * `:rpc_call` - injectable `:rpc.call/5` (tests)
    * `:nodes` - injectable node list for discovery (tests)
  """
  @spec gateway_node(keyword()) :: {:ok, node()} | {:error, :gateway_unavailable}
  def gateway_node(opts) do
    case Keyword.get(opts, :gateway_node) do
      node when is_atom(node) and not is_nil(node) -> {:ok, node}
      _ -> discover_gateway_node(opts)
    end
  end

  @doc "Issues one certificate on `node`. `issuer_opts` go to the gateway's `CertIssuer`."
  @spec issue(node(), String.t(), String.t(), atom(), keyword(), keyword()) ::
          {:ok, bundle()} | {:error, :gateway_unavailable | {:issue_failed, term()}}
  def issue(node, component_id, partition_id, component_type, issuer_opts, opts) do
    rpc_call = Keyword.get(opts, :rpc_call, &:rpc.call/5)

    case rpc_call.(
           node,
           @gateway_cert_issuer,
           :issue_agent_bundle,
           [component_id, partition_id, component_type, issuer_opts],
           @rpc_timeout
         ) do
      {:ok, %{certificate_pem: _, private_key_pem: _, ca_chain_pem: _} = bundle} ->
        {:ok, bundle}

      {:error, reason} ->
        {:error, {:issue_failed, reason}}

      {:badrpc, reason} ->
        Logger.warning("[GatewayCertificates] gateway RPC failed: #{inspect(reason)}")
        {:error, :gateway_unavailable}

      other ->
        {:error, {:issue_failed, other}}
    end
  end

  # GatewayTracker lives on core nodes; ask each connected node for an active
  # gateway and take the first one that reports a node.
  defp discover_gateway_node(opts) do
    rpc_call = Keyword.get(opts, :rpc_call, &:rpc.call/5)
    nodes = Keyword.get_lazy(opts, :nodes, fn -> [Node.self() | Node.list()] end)

    Enum.find_value(nodes, {:error, :gateway_unavailable}, fn node ->
      case rpc_call.(node, ServiceRadar.GatewayTracker, :list_gateways, [], 2_000) do
        gateways when is_list(gateways) ->
          Enum.find_value(gateways, fn
            %{active: true, node: gateway_node} when is_atom(gateway_node) -> {:ok, gateway_node}
            _ -> nil
          end)

        _ ->
          nil
      end
    end)
  end
end
