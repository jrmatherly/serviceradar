defmodule ServiceRadarAgentGateway.CertIssuerCollectorTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.CertIssuer

  # Not ExUnit's :tmp_dir: its path includes the test name, and under Bazel the
  # result exceeds what openssl accepts.
  setup do
    dir = Path.join(System.tmp_dir!(), "cert-issuer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    ca_cert = Path.join(dir, "root.pem")
    ca_key = Path.join(dir, "root-key.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256"] ++
          ["-keyout", ca_key, "-out", ca_cert, "-days", "1", "-subj", "/CN=Invented Test CA"],
        stderr_to_stdout: true
      )

    %{dir: dir, opts: [ca_cert_file: ca_cert, ca_key_file: ca_key, temp_parent_dir: dir, audit_writer: nil]}
  end

  test "issues a collector identity with the CN a leaf server maps", %{opts: opts} do
    assert {:ok, bundle} = CertIssuer.issue_agent_bundle("trapd-abc123", "partition-a", :collector, opts)

    assert bundle.cn == "trapd-abc123.partition-a.serviceradar"
    assert bundle.spiffe_id == "spiffe://serviceradar.local/collector/partition-a/trapd-abc123"
  end

  test "a collector identity carries no leaf role", %{opts: opts, dir: dir} do
    assert {:ok, bundle} = CertIssuer.issue_agent_bundle("trapd-abc123", "partition-a", :collector, opts)

    cert = Path.join(dir, "collector.pem")
    File.write!(cert, bundle.certificate_pem)

    {text, 0} =
      System.cmd("openssl", ["x509", "-in", cert, "-noout", "-ext", "subjectAltName"], stderr_to_stdout: true)

    assert text =~ "trapd-abc123.partition-a.serviceradar"

    refute text =~ CertIssuer.nats_leaf_role_uri("partition-a")
  end

  test "a type outside the allowlist is still refused", %{opts: opts} do
    assert {:error, :unsupported_component_type} =
             CertIssuer.issue_agent_bundle("trapd-abc123", "partition-a", :collectorish, opts)
  end
end
