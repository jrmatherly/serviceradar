defmodule ServiceRadar.Edge.CollectorCertificateIssuerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CollectorCertificateIssuer

  @package %{id: "11111111-2222-4333-8444-555555555555", collector_type: :trapd}
  @component_id "trapd-11111111222243338444555555555555"

  defp gateway(node, rpc_result) do
    test_pid = self()

    fn
      ^node, ServiceRadarAgentGateway.CertIssuer, :issue_agent_bundle, args, _timeout ->
        send(test_pid, {:issue_args, args})
        rpc_result

      _node, ServiceRadar.GatewayTracker, :list_gateways, [], _timeout ->
        [%{active: true, node: node}]
    end
  end

  test "asks a live gateway for a collector certificate and returns the :ready arguments" do
    bundle = %{certificate_pem: "cert", private_key_pem: "key", ca_chain_pem: "ca"}

    assert {:ok, %{tls_cert_pem: "cert", tls_key_pem: "key", ca_chain_pem: "ca"}} =
             CollectorCertificateIssuer.issue(@package,
               partition_id: "partition-a",
               nodes: [:core@host01],
               rpc_call: gateway(:gateway@host01, {:ok, bundle})
             )

    assert_received {:issue_args, [@component_id, "partition-a", :collector, issuer_opts]}
    assert %{id: "system"} = issuer_opts[:audit_actor]
  end

  test "no live gateway is retryable, not a certificate failure" do
    assert {:error, :gateway_unavailable} =
             CollectorCertificateIssuer.issue(@package,
               nodes: [:core@host01],
               rpc_call: fn _node, _module, _function, _args, _timeout -> [] end
             )
  end

  test "a gateway lost between discovery and the call is retryable too" do
    assert {:error, :gateway_unavailable} =
             CollectorCertificateIssuer.issue(@package,
               nodes: [:core@host01],
               rpc_call: gateway(:gateway@host01, {:badrpc, :nodedown})
             )
  end

  test "a gateway refusal keeps its reason" do
    assert {:error, {:collector_certificate_issue_failed, :ca_not_available}} =
             CollectorCertificateIssuer.issue(@package,
               nodes: [:core@host01],
               rpc_call: gateway(:gateway@host01, {:error, :ca_not_available})
             )
  end

  test "every package type gets an identity the gateway's token rule accepts" do
    for type <- [:flowgger, :otel, :trapd, :netflow, :sflow] do
      id = CollectorCertificateIssuer.component_id(%{@package | collector_type: type})
      assert id =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/
      assert String.starts_with?(id, "#{type}-")
    end
  end
end
