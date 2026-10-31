defmodule ServiceRadar.Edge.NatsLeafConfigGeneratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CollectorCertificateIssuer
  alias ServiceRadar.Edge.NatsLeafConfigGenerator
  alias ServiceRadar.Edge.Workers.ProvisionCollectorWorker

  test "renders exact assignment subject permissions without a broad events grant" do
    config =
      NatsLeafConfigGenerator.render_direct_leaf_authorization([
        %{
          component_id: "addon-ff68b63bec90435e952b24e211067596",
          partition_id: "partition-a",
          # The renderer must ignore any accidental material fields; the leaf
          # bundle receives only the certificate identity and subject scope.
          certificate_pem: "-----BEGIN CERTIFICATE-----secret",
          private_key_pem: "-----BEGIN PRIVATE KEY-----secret",
          scope: %{
            "publish" => [
              "events.otlp.traces.>",
              "events.otlp.metrics.>",
              "logs.otel",
              "$JS.API.STREAM.INFO.events"
            ],
            "subscribe" => ["_INBOX.>", "$JS.ACK.events.>"]
          }
        }
      ])

    assert config =~ "CN=addon-ff68b63bec90435e952b24e211067596.partition-a.serviceradar"
    assert config =~ "events.otlp.traces.>"
    assert config =~ "$JS.ACK.events.>"
    refute config =~ "BEGIN CERTIFICATE"
    refute config =~ "BEGIN PRIVATE KEY"
    refute config =~ "\"events.>\""
    refute config =~ "account_seed"
  end

  describe "local authorization" do
    @site %{name: "Site 01", slug: "site01", nats_leaf_url: nil}
    @leaf %{upstream_url: "tls://hub.example.com:7422", local_listen: "0.0.0.0:4222"}
    @fixtures Path.expand("../../../../../go/pkg/cli/testdata", __DIR__)

    defp collector_identity(type, suffix) do
      CollectorCertificateIssuer.leaf_identity(
        %{id: "11111111-2222-4333-8444-55555555000#{suffix}", collector_type: type},
        partition_id: "default"
      )
    end

    defp all_collectors do
      Enum.map([flowgger: 1, trapd: 2, otel: 3, netflow: 4, sflow: 5], fn {type, suffix} ->
        collector_identity(type, suffix)
      end)
    end

    defp without_timestamp(config) do
      config |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "# Generated at:"))
    end

    test "a leaf with no identities still authenticates every local client" do
      config = NatsLeafConfigGenerator.generate_config(@site, @leaf)

      assert config =~ "authorization {"
      assert config =~ ~s(user: "CN=no-identity-assigned.invalid")
    end

    test "defaults grant nothing, and no list reads as unrestricted" do
      config = NatsLeafConfigGenerator.generate_config(@site, @leaf)

      assert config =~ ~s(publish: { deny: [">"] })
      assert config =~ ~s(subscribe: { deny: [">"] })
      refute config =~ "$JS.API.>"
      refute config =~ ~r/allow:\s*\[\s*\]/
    end

    test "a user with an empty grant is denied rather than left unrestricted" do
      config =
        NatsLeafConfigGenerator.render_direct_leaf_authorization([
          %{component_id: "c", partition_id: "p", scope: %{publish: [], subscribe: []}}
        ])

      refute config =~ ~r/allow:\s*\[\s*\]/
      assert config =~ ~s(CN=c.p.serviceradar)
    end

    test "collector users hold exactly the subjects of their credential" do
      for {type, suffix} <- [flowgger: 1, trapd: 2, otel: 3, netflow: 4, sflow: 5] do
        identity = collector_identity(type, suffix)
        permissions = ProvisionCollectorWorker.collector_permissions(type)

        assert identity.component_id == "#{type}-1111111122224333844455555555000#{suffix}"
        assert identity.partition_id == "default"
        assert identity.scope.publish == permissions.publish_allow
        assert identity.scope.subscribe == permissions.subscribe_allow

        config = NatsLeafConfigGenerator.render_direct_leaf_authorization([identity])
        assert config =~ "CN=#{identity.component_id}.default.serviceradar"
        for subject <- permissions.publish_allow, do: assert(config =~ subject)
      end
    end

    # go/pkg/cli's TestLeafEnforcesCollectorAuthorization loads these into a real server.
    test "the rendered config with collectors matches the Go test's fixture" do
      rendered =
        NatsLeafConfigGenerator.generate_config(@site, @leaf,
          direct_leaf_identities: all_collectors()
        )

      assert without_timestamp(rendered) ==
               @fixtures
               |> Path.join("leaf-collectors.conf")
               |> File.read!()
               |> without_timestamp()
    end

    test "the rendered config without collectors matches the Go test's fixture" do
      rendered = NatsLeafConfigGenerator.generate_config(@site, @leaf)

      assert without_timestamp(rendered) ==
               @fixtures
               |> Path.join("leaf-no-collectors.conf")
               |> File.read!()
               |> without_timestamp()
    end
  end

  describe "client_url/1" do
    test "a wildcard bind becomes the loopback TLS URL collectors dial" do
      assert NatsLeafConfigGenerator.client_url("0.0.0.0:4222") == "tls://127.0.0.1:4222"
      assert NatsLeafConfigGenerator.client_url("*:4222") == "tls://127.0.0.1:4222"
      assert NatsLeafConfigGenerator.client_url("[::]:4222") == "tls://[::1]:4222"
    end

    test "a specific listen address keeps its host" do
      assert NatsLeafConfigGenerator.client_url("192.0.2.10:4222") == "tls://192.0.2.10:4222"
      assert NatsLeafConfigGenerator.client_url("tls://127.0.0.1:4222") == "tls://127.0.0.1:4222"
    end

    test "a missing listen address defaults to loopback" do
      assert NatsLeafConfigGenerator.client_url(nil) == "tls://127.0.0.1:4222"
      assert NatsLeafConfigGenerator.client_url("  ") == "tls://127.0.0.1:4222"
    end
  end

  describe "edge-site leaf bundle templates" do
    @site %{name: "NYC Office", slug: "nyc-office", nats_leaf_url: "tls://10.0.1.50:4222"}
    @leaf %{upstream_url: "tls://acme.nats.serviceradar.cloud:7422", local_listen: "0.0.0.0:4222"}

    test "the leaf remote dials the leaf server's upstream URL" do
      config = NatsLeafConfigGenerator.generate_config(@site, @leaf)

      assert config =~ ~s(url: "tls://acme.nats.serviceradar.cloud:7422")
      assert config =~ ~s(cert_file: "/etc/nats/certs/nats-leaf.pem")
    end

    test "references account creds only when the bundle ships them" do
      refute NatsLeafConfigGenerator.generate_config(@site, @leaf) =~ "credentials:"

      assert NatsLeafConfigGenerator.generate_config(@site, @leaf, with_credentials: true) =~
               ~s(credentials: "/etc/nats/creds/account.creds")
    end

    test "setup script manages the serviceradar-nats unit with packaged ownership" do
      script = NatsLeafConfigGenerator.generate_setup_script(@site)

      assert script =~ "UNIT=serviceradar-nats"
      assert script =~ ~s(systemctl restart "$UNIT")
      refute script =~ "nats-server.service"
      refute script =~ "systemctl enable nats-server"
      assert script =~ "-o nats -g serviceradar"
      refute script =~ "nats:nats"
      assert script =~ "nats-server -c nats/nats-leaf.conf -t"
      refute script =~ "account.creds"

      assert NatsLeafConfigGenerator.generate_setup_script(@site, with_credentials: true) =~
               "creds/account.creds /etc/nats/creds/account.creds"
    end

    test "setup script is valid bash" do
      path = Path.join(System.tmp_dir!(), "leaf-setup-#{System.unique_integer([:positive])}.sh")

      File.write!(
        path,
        NatsLeafConfigGenerator.generate_setup_script(@site, with_credentials: true)
      )

      on_exit(fn -> File.rm(path) end)

      assert {_, 0} = System.cmd("bash", ["-n", path], stderr_to_stdout: true)
    end
  end
end
