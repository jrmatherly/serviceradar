defmodule ServiceRadarWebNG.Edge.CollectorBundleGeneratorTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.Workers.ProvisionCollectorWorker
  alias ServiceRadar.EventWriter.Config, as: EventWriterConfig
  alias ServiceRadarWebNG.Edge.CollectorBundleGenerator

  @moduletag :db_free

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "create_tarball/4 for falcosidekick" do
    test "does not bundle a second certificate set" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_falcosidekick_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      files = extract_files(tarball)
      file_names = Map.keys(files)

      assert Enum.any?(file_names, &String.ends_with?(&1, "/creds/nats.creds"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/falcosidekick.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/deploy.sh"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/README.md"))

      refute Enum.any?(file_names, &String.contains?(&1, "/certs/"))
    end

    test "extracts with a runnable deploy script" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(sample_falcosidekick_package(), sample_nats_creds(), nil,
          nats_url: "nats://serviceradar-nats:4222"
        )

      modes = tar_modes(tarball)

      assert modes["deploy.sh"] == 0o755
      assert modes["creds/nats.creds"] == 0o600
    end

    test "publishes on the one subject the events stream captures by default" do
      values = falcosidekick_values(sample_falcosidekick_package())

      assert values["config"]["nats"]["subjecttemplate"] == "falco.logs"
    end

    test "projects only the required files from the shared runtime cert secret" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_falcosidekick_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      files = extract_files(tarball)
      values_yaml = find_file(files, "falcosidekick.yaml")
      deploy_script = find_file(files, "deploy.sh")
      readme = find_file(files, "README.md")
      values = YamlElixir.read_from_string!(values_yaml)
      cert_volume = Enum.find(values["extraVolumes"], &(&1["name"] == "serviceradar-certs"))

      assert values_yaml =~ "secretName: serviceradar-runtime-certs"

      assert cert_volume["secret"] == %{
               "secretName" => "serviceradar-runtime-certs",
               "items" => [
                 %{"key" => "root.pem", "path" => "root.pem"},
                 %{"key" => "falcosidekick.pem", "path" => "falcosidekick.pem"},
                 %{"key" => "falcosidekick-key.pem", "path" => "falcosidekick-key.pem"}
               ]
             }

      assert values_yaml =~ "cacertfile: /etc/serviceradar/certs/root.pem"
      assert values_yaml =~ "templatedfields:"

      assert values_yaml =~
               ~s(serviceradar.agent_id: '{{ with index . "k8s.node.name" }}agent-{{ . }}{{ end }}')

      assert values_yaml =~
               "OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE: /etc/serviceradar/certs/root.pem"

      refute values_yaml =~ "serviceradar-falcosidekick-certs"
      refute values_yaml =~ "/etc/serviceradar/certs/ca-chain.pem"
      refute values_yaml =~ "root-key.pem"
      refute values_yaml =~ "jwt-secret"
      refute values_yaml =~ "api-key"

      assert deploy_script =~ ~s(SECRET_NAME="serviceradar-runtime-certs")
      assert deploy_script =~ ~s(kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE")
      refute deploy_script =~ "kubectl create secret generic"
      refute deploy_script =~ "serviceradar-falcosidekick-certs"

      assert readme =~ "serviceradar-runtime-certs"
      refute readme =~ "serviceradar-falcosidekick-certs"
      refute readme =~ "certs/client.pem"
    end
  end

  describe "create_tarball/4 for otel" do
    test "normalizes newline-bearing grpc port overrides before writing TOML" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_otel_package(%{
            "server" => %{"port" => "4317\nmalicious = true"}
          }),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      files = extract_files(tarball)
      otel_toml = find_file(files, "otel.toml")

      assert otel_toml =~ "port = 4317"
      refute otel_toml =~ "malicious = true"
    end
  end

  describe "create_tarball/4 for flowgger" do
    test "installs into the service the package provides" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_flowgger_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      assert {:ok, installed} = install_bundle(tarball)
      assert File.read!(Path.join(installed, "creds/flowgger.creds")) =~ "BEGIN NATS USER JWT"
      assert File.exists?(Path.join(installed, "flowgger.toml"))
    end

    test "installs certificate files when the bundle includes them" do
      package = %{
        sample_flowgger_package()
        | tls_cert_pem: "cert-pem\n",
          ca_chain_pem: "ca-pem\n"
      }

      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          package,
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      assert {:ok, installed} = install_bundle(tarball)

      assert File.read!(Path.join(installed, "certs/flowgger.pem")) == "cert-pem\n"
      assert File.read!(Path.join(installed, "certs/flowgger-key.pem")) == sample_tls_key()
      assert File.read!(Path.join(installed, "certs/ca-chain.pem")) == "ca-pem\n"
      assert mode(Path.join(installed, "certs/flowgger.pem")) == 0o644
      assert mode(Path.join(installed, "certs/ca-chain.pem")) == 0o644
      assert mode(Path.join(installed, "certs/flowgger-key.pem")) == 0o600
      assert mode(Path.join(installed, "creds/flowgger.creds")) == 0o600
    end

    test "update.sh reports success only when the unit stays up" do
      package = %{sample_flowgger_package() | tls_cert_pem: "cert-pem\n", ca_chain_pem: "ca-pem\n"}

      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), sample_tls_key(),
          nats_url: "tls://host01.example.com:4222"
        )

      script = tarball |> extract_files() |> find_file("update.sh")
      assert {_, 0} = System.cmd("bash", ["-n", "-c", script], stderr_to_stdout: true)

      assert {:ok, _installed} = install_bundle(tarball)

      assert {:error, {status, output}} = install_bundle(tarball, nil, false)
      assert status != 0
      assert output =~ "journalctl -u serviceradar-log-collector"
      refute output =~ "Update complete"
    end

    test "extracts with a runnable script and private secrets" do
      package = %{sample_flowgger_package() | tls_cert_pem: "cert-pem\n", ca_chain_pem: "ca-pem\n"}

      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), sample_tls_key(),
          nats_url: "tls://host01.example.com:4222"
        )

      modes = tar_modes(tarball)

      assert modes["update.sh"] == 0o755
      assert modes["creds/nats.creds"] == 0o600
      assert modes["certs/collector-key.pem"] == 0o600
      assert modes["certs/collector.pem"] == 0o644
    end

    test "defaults syslog input to auto detection and UTC" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_flowgger_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://host01.example.com:4222"
        )

      flowgger_toml = tarball |> extract_files() |> find_file("flowgger.toml")

      assert flowgger_toml =~ ~s(format = "auto")
      assert flowgger_toml =~ ~s(rfc3164_timezone = "UTC")
    end

    test "preserves explicit RFC3164 and legacy timezone overrides" do
      for {input, timezone} <- [
            {%{"rfc3164_timezone" => "local"}, "local"},
            {%{"timezone" => "America/New_York"}, "America/New_York"},
            {%{"rfc3164_timezone" => "UTC", "timezone" => "America/New_York"}, "UTC"}
          ] do
        {:ok, tarball} =
          CollectorBundleGenerator.create_tarball(
            sample_flowgger_package(%{"input" => input}),
            sample_nats_creds(),
            sample_tls_key(),
            nats_url: "nats://host01.example.com:4222"
          )

        flowgger_toml = tarball |> extract_files() |> find_file("flowgger.toml")

        assert flowgger_toml =~ ~s(rfc3164_timezone = "#{timezone}")
      end
    end
  end

  describe "create_tarball/4 for the log collector" do
    # Literal values from build/packaging/log-collector: the one package holds both
    # pipelines, and its unit reads log-collector.toml, which names these two files.
    @log_collector_unit "ExecStart=/usr/local/bin/serviceradar-log-collector --config /etc/serviceradar/log-collector.toml"

    for {type, config_file, section} <- [
          {:flowgger, "flowgger.toml", "flowgger"},
          {:otel, "otel.toml", "otel"}
        ] do
      test "#{type} installs into the package's service and the file it reads" do
        unit =
          File.read!(Path.join(@repo_root, "build/packaging/log-collector/systemd/serviceradar-log-collector.service"))

        package_config =
          File.read!(Path.join(@repo_root, "build/packaging/log-collector/config/log-collector.toml"))

        assert unit =~ @log_collector_unit

        assert package_config =~
                 ~s([#{unquote(section)}]\nenabled = true\nconfig_file = "/etc/serviceradar/#{unquote(config_file)}")

        {:ok, tarball} =
          CollectorBundleGenerator.create_tarball(
            sample_flow_package(unquote(type)),
            sample_nats_creds(),
            sample_tls_key(),
            nats_url: "tls://host01.example.com:4222"
          )

        assert {:ok, installed} = install_bundle(tarball)
        assert File.exists?(Path.join(installed, unquote(config_file)))

        log = File.read!(Path.join(installed, "systemctl.log"))
        assert log =~ "stop serviceradar-log-collector"
        assert log =~ "start serviceradar-log-collector"

        readme = tarball |> extract_files() |> find_file("README.md")
        assert readme =~ "apt install serviceradar-log-collector"
        assert readme =~ "dnf install serviceradar-log-collector"
        refute readme =~ "serviceradar-#{unquote(type)}"
      end
    end

    test "flowgger and otel on one host keep separate identities" do
      flowgger = sample_flow_package(:flowgger)
      otel = sample_flow_package(:otel)

      config = Path.join(System.tmp_dir!(), "collector-shared-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(config) end)

      for {package, cert} <- [{flowgger, "flowgger-cert\n"}, {otel, "otel-cert\n"}] do
        {:ok, tarball} =
          CollectorBundleGenerator.create_tarball(
            %{package | tls_cert_pem: cert},
            "#{package.collector_type}-creds\n",
            sample_tls_key(),
            nats_url: "tls://host01.example.com:4222"
          )

        assert {:ok, ^config} = install_bundle(tarball, config)
      end

      assert File.read!(Path.join(config, "certs/flowgger.pem")) == "flowgger-cert\n"
      assert File.read!(Path.join(config, "certs/otel.pem")) == "otel-cert\n"
      assert File.read!(Path.join(config, "creds/flowgger.creds")) == "flowgger-creds\n"
      assert File.read!(Path.join(config, "creds/otel.creds")) == "otel-creds\n"
      assert File.exists?(Path.join(config, "flowgger.toml"))
      assert File.exists?(Path.join(config, "otel.toml"))
    end

    # The Rust tests parse these fixtures with the real config types.
    for {type, fixture, file} <- [
          {:flowgger, "rust/flowgger/testdata/edge-flowgger.toml", "flowgger.toml"},
          {:otel, "rust/otel/testdata/edge-otel.toml", "otel.toml"}
        ] do
      test "#{type} output matches the fixture its binary parses" do
        expected = @repo_root |> Path.join(unquote(fixture)) |> File.read!() |> toml_settings()
        assert unquote(type) |> sample_flow_package() |> bundle_text(unquote(file)) |> toml_settings() == expected
      end
    end
  end

  describe "create_tarball/4 for trapd" do
    test "installs into the unit the package ships" do
      unit = File.read!(Path.join(@repo_root, "build/packaging/trapd/systemd/serviceradar-trapd.service"))
      assert unit =~ "ExecStart=/usr/local/bin/serviceradar-trapd --config /etc/serviceradar/trapd.json"

      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(sample_flow_package(:trapd), sample_nats_creds(), sample_tls_key(),
          nats_url: "tls://host01.example.com:4222"
        )

      assert {:ok, installed} = install_bundle(tarball)
      assert File.exists?(Path.join(installed, "trapd.json"))
      assert File.read!(Path.join(installed, "systemctl.log")) =~ "start serviceradar-trapd"
    end

    test "output matches the fixture trapd parses" do
      expected =
        @repo_root |> Path.join("rust/trapd/testdata/edge-trapd.json") |> File.read!() |> Jason.decode!()

      assert bundle_json(sample_flow_package(:trapd), "trapd.json") == expected
    end
  end

  describe "create_tarball/4 without TLS material" do
    # Every host collector config says mode mtls and nothing else puts certs on the
    # host, so such a bundle could only fail at connect time.
    for type <- [:flowgger, :otel, :trapd, :netflow, :sflow] do
      test "#{type} refuses rather than ship an mTLS config with no certificates" do
        package = %{sample_flow_package(unquote(type)) | tls_cert_pem: nil, ca_chain_pem: nil}

        assert {:error, :tls_material_missing} =
                 CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), nil,
                   nats_url: "tls://host01.example.com:4222"
                 )
      end
    end

    test "a package missing any one file also refuses" do
      assert {:error, :tls_material_missing} =
               CollectorBundleGenerator.create_tarball(
                 sample_flow_package(:netflow),
                 sample_nats_creds(),
                 nil,
                 nats_url: "tls://host01.example.com:4222"
               )
    end
  end

  describe "create_tarball/4 for flow collectors" do
    for type <- [:netflow, :sflow] do
      test "#{type} installs into the unit the flow-collector package ships" do
        unit_name = "serviceradar-flow-collector.service"

        unit =
          [@repo_root, "build/packaging/flow-collector/systemd", unit_name]
          |> Path.join()
          |> File.read!()

        [_, config_path] = Regex.run(~r/^ExecStart=\S+ --config (\S+)$/m, unit)

        {:ok, tarball} =
          CollectorBundleGenerator.create_tarball(
            sample_flow_package(unquote(type)),
            sample_nats_creds(),
            sample_tls_key(),
            nats_url: "tls://host01.example.com:4222"
          )

        assert {:ok, installed} = install_bundle(tarball)
        assert File.exists?(Path.join(installed, Path.basename(config_path)))

        log = File.read!(Path.join(installed, "systemctl.log"))
        assert log =~ "stop serviceradar-flow-collector"
        assert log =~ "start serviceradar-flow-collector"

        readme = tarball |> extract_files() |> find_file("README.md")
        assert readme =~ "apt install serviceradar-flow-collector"
        assert readme =~ "dnf install serviceradar-flow-collector"
        refute readme =~ "serviceradar-#{unquote(type)}"
      end
    end

    test "netflow bundle uses flow-collector listeners" do
      config = flow_bundle_config(sample_flow_package(:netflow))

      assert config["stream_name"] == "flows"
      assert config["stream_owner"] == false

      assert config["listeners"] == [
               %{
                 "protocol" => "netflow",
                 "listen_addr" => "0.0.0.0:2055",
                 "subject" => "flows.raw.netflow"
               }
             ]

      refute Map.has_key?(config, "subject")
      refute Map.has_key?(config, "listen_addr")
    end

    test "sflow bundle uses flow-collector listeners" do
      config = flow_bundle_config(sample_flow_package(:sflow))

      assert config["stream_name"] == "flows"
      assert config["stream_owner"] == false

      assert config["listeners"] == [
               %{
                 "protocol" => "sflow",
                 "listen_addr" => "0.0.0.0:6343",
                 "subject" => "flows.raw.sflow"
               }
             ]

      refute Map.has_key?(config, "subject")
      refute Map.has_key?(config, "listen_addr")
    end

    test "a listen_addr override reaches the listener" do
      config =
        flow_bundle_config(sample_flow_package(:netflow, %{"listen_addr" => "192.0.2.10:9995"}))

      assert [%{"listen_addr" => "192.0.2.10:9995"}] = config["listeners"]
    end

    test "credentials and TLS paths resolve to where update.sh installs them" do
      package = sample_flow_package(:netflow)

      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), sample_tls_key(),
          nats_url: "tls://host01.example.com:4222"
        )

      files = extract_files(tarball)
      config = files |> find_file("flow-collector.json") |> Jason.decode!()
      update_script = find_file(files, "update.sh")

      assert config["nats_creds_file"] == "/etc/serviceradar/creds/flow-collector.creds"
      assert %{"mode" => "mtls", "cert_dir" => "/etc/serviceradar/certs", "tls" => tls} = config["security"]

      assert update_script =~ ~s(CERTS_DIR="$CONFIG_DIR/certs")
      assert update_script =~ ~s(CREDS_DIR="$CONFIG_DIR/creds")

      assert update_script =~ ~s("$CREDS_DIR/flow-collector.creds")

      for file <- Map.values(tls) do
        assert update_script =~ ~s("$CERTS_DIR/#{file}")
      end
    end

    for {type, fixture} <- [netflow: "edge-netflow.json", sflow: "edge-sflow.json"] do
      test "#{type} output matches the fixture flow-collector parses" do
        expected =
          [@repo_root, "rust/flow-collector/testdata", unquote(fixture)]
          |> Path.join()
          |> File.read!()
          |> Jason.decode!()

        assert flow_bundle_config(sample_flow_package(unquote(type))) == expected
      end
    end
  end

  describe "bundle subjects" do
    # A subject no stream captures is acknowledged by nobody, so each one must land
    # in a stream EventWriter creates and be publishable with the edge credential.
    test "each is captured by a stream EventWriter creates and allowed by the credential" do
      streams = EventWriterConfig.default_streams() ++ EventWriterConfig.default_flow_streams()

      for {type, stream_name, subject} <- bundle_subjects() do
        assert Enum.any?(streams, &captures?(&1, stream_name, subject)),
               "#{type}: no EventWriter stream #{stream_name} captures #{subject}"

        assert subject in ProvisionCollectorWorker.collector_permissions(type).publish_allow
      end
    end

    test "a subject outside every EventWriter stream is not reported as captured" do
      streams = EventWriterConfig.default_flow_streams()

      refute Enum.any?(streams, &captures?(&1, "flows", "flows.raw.unknown"))
      refute Enum.any?(streams, &captures?(&1, "events", "flows.raw.netflow"))
    end
  end

  describe "get_nats_url/2" do
    @tag :db_free
    test "an edge site with no leaf URL writes to the local leaf" do
      package = %CollectorPackage{
        collector_type: :flowgger,
        edge_site: %EdgeSite{nats_leaf_url: nil, nats_leaf_server: %{local_listen: "0.0.0.0:4222"}}
      }

      assert CollectorBundleGenerator.get_nats_url(package) == "tls://127.0.0.1:4222"
    end

    @tag :db_free
    test "the README names the URL the bundle dials when the site has no leaf URL" do
      package = %{
        sample_flow_package(:netflow)
        | edge_site: %EdgeSite{name: "Edge", nats_leaf_url: nil, nats_leaf_server: %{local_listen: "0.0.0.0:4222"}}
      }

      readme = bundle_text(package, "README.md")

      assert readme =~ "**NATS Leaf URL:** tls://"
      refute readme =~ "Not configured"
      refute readme =~ "buffering when"
    end

    test "an explicit edge site leaf URL overrides the local listen address" do
      package = %CollectorPackage{
        collector_type: :netflow,
        edge_site: %EdgeSite{
          nats_leaf_url: "tls://192.0.2.10:4222",
          nats_leaf_server: %{local_listen: "0.0.0.0:4222"}
        }
      }

      assert CollectorBundleGenerator.get_nats_url(package) == "tls://192.0.2.10:4222"
    end

    @tag :db_free
    test "a collector with no edge site gets the externally reachable hub URL, not the cluster's" do
      put_web_ng_env(:nats_url, "nats://nats:4222")
      put_web_ng_env(:collector_nats_url, "tls://nats.example.com:4222")

      assert CollectorBundleGenerator.get_nats_url(%CollectorPackage{collector_type: :sflow}) ==
               "tls://nats.example.com:4222"
    end
  end

  describe "create_tarball/4 with no external hub URL" do
    setup do
      put_web_ng_env(:nats_url, "nats://nats:4222")
      Application.delete_env(:serviceradar_web_ng, :collector_nats_url)
    end

    test "a hub-direct host bundle refuses rather than ship an internal hostname" do
      package = %{sample_flow_package(:netflow) | edge_site: nil}

      assert {:error, :collector_nats_url_missing} =
               CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), sample_tls_key())

      refute CollectorBundleGenerator.nats_url_configured?(package)
    end

    test "a bundle for an edge site still builds, since it dials the leaf" do
      package = %{sample_flow_package(:netflow) | edge_site: %EdgeSite{name: "Edge", nats_leaf_url: nil}}

      assert {:ok, _tarball} =
               CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), sample_tls_key())

      assert CollectorBundleGenerator.nats_url_configured?(%{package | edge_site_id: Ecto.UUID.generate()})
    end

    test "falcosidekick deploys into the cluster and keeps the cluster URL" do
      package = sample_falcosidekick_package()

      assert {:ok, tarball} = CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), nil)

      values = tarball |> extract_files() |> find_file("falcosidekick.yaml") |> YamlElixir.read_from_string!()
      assert values["config"]["nats"]["hostport"] == "nats://nats:4222"
      assert CollectorBundleGenerator.nats_url_configured?(package)
    end
  end

  describe "CollectorPackage :create" do
    test "refuses an edge site for falcosidekick, which has no user on a leaf" do
      changeset =
        Ash.Changeset.for_create(CollectorPackage, :create, %{
          collector_type: :falcosidekick,
          edge_site_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert [%{fields: [:edge_site_id]}] = changeset.errors
    end

    test "allows an edge site for a host collector" do
      changeset =
        Ash.Changeset.for_create(CollectorPackage, :create, %{
          collector_type: :flowgger,
          edge_site_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end
  end

  describe "service_name/1" do
    test "names a package build/packaging/components.json ships" do
      packages =
        @repo_root
        |> Path.join("build/packaging/components.json")
        |> File.read!()
        |> Jason.decode!()
        |> Enum.map(& &1["package_name"])

      for type <- [:flowgger, :otel, :trapd, :netflow, :sflow] do
        assert CollectorBundleGenerator.service_name(%{collector_type: type}) in packages
      end
    end
  end

  describe "update_command/3" do
    test "uses the public collector bundle path for standard collectors" do
      command =
        CollectorBundleGenerator.update_command(
          %CollectorPackage{
            id: "12345678-abcd-efgh-ijkl-1234567890ab",
            collector_type: :flowgger
          },
          "sentinel-token-value",
          base_url: "https://demo.serviceradar.cloud"
        )

      assert command =~
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle"

      assert command =~ "-X POST"
      assert command =~ "x-serviceradar-download-token: ${SR_TOKEN}"
      # The header name contains "download-token"; the SECRET passed to
      # update_command/3 is the sentinel and must never be embedded verbatim.
      refute command =~ "sentinel-token-value"
      assert command =~ "sudo ./update.sh"
      refute command =~ "/api/edge/collectors/"
    end

    test "uses deploy.sh for falcosidekick bundles" do
      command =
        CollectorBundleGenerator.update_command(
          sample_falcosidekick_package(),
          "sentinel-token-value",
          base_url: "https://demo.serviceradar.cloud"
        )

      assert command =~
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle"

      assert command =~ "-X POST"
      assert command =~ "x-serviceradar-download-token: ${SR_TOKEN}"
      refute command =~ "sentinel-token-value"
      assert command =~ "./deploy.sh"
      refute command =~ "sudo ./update.sh"
    end

    test "quotes bundle URLs as shell literals" do
      command =
        CollectorBundleGenerator.update_command(
          %CollectorPackage{
            id: "12345678-abcd-efgh-ijkl-1234567890ab",
            collector_type: :flowgger
          },
          "download-token",
          base_url: "https://demo.serviceradar.cloud/$(touch /tmp/pwned)"
        )

      assert command =~
               "'https://demo.serviceradar.cloud/$(touch /tmp/pwned)/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle'"

      refute command =~
               "\"https://demo.serviceradar.cloud/$(touch /tmp/pwned)/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle\""
    end
  end

  defp install_bundle(tarball, config \\ nil, unit_active? \\ true) do
    root = Path.join(System.tmp_dir!(), "collector-update-#{System.unique_integer([:positive])}")
    bundle = Path.join(root, "bundle")
    config = config || Path.join(root, "etc")
    bin = Path.join(root, "bin")
    log = Path.join(config, "systemctl.log")

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(bundle)
    File.mkdir_p!(bin)
    File.mkdir_p!(config)
    File.write!(log, "")

    Enum.each(extract_files(tarball), fn {name, content} ->
      relative = name |> String.split("/", parts: 2) |> List.last()
      dest = Path.join(bundle, relative)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    end)

    script_path = Path.join(bundle, "update.sh")

    script =
      script_path
      |> File.read!()
      |> String.replace(~s([ "$EUID" -ne 0 ]), ~s([ "${SR_TEST_EUID:-$EUID}" -ne 0 ]))
      |> String.replace(~s(CONFIG_DIR="/etc/serviceradar"), ~s(CONFIG_DIR="#{config}"))

    File.write!(script_path, script)
    File.write!(Path.join(bin, "systemctl"), stub_systemctl(log, unit_active?))
    File.write!(Path.join(bin, "id"), "#!/bin/bash\nexit 1\n")
    File.write!(Path.join(bin, "sleep"), "#!/bin/bash\nexit 0\n")
    File.chmod!(Path.join(bin, "systemctl"), 0o755)
    File.chmod!(Path.join(bin, "id"), 0o755)
    File.chmod!(Path.join(bin, "sleep"), 0o755)

    env =
      System.get_env()
      |> Map.put("PATH", bin <> ":" <> System.get_env("PATH", ""))
      |> Map.put("SR_TEST_EUID", "0")
      |> Map.to_list()

    {output, status} = System.cmd("bash", [script_path], env: env, stderr_to_stdout: true)

    if status == 0 do
      {:ok, config}
    else
      {:error, {status, output}}
    end
  end

  defp stub_systemctl(log, unit_active?) do
    """
    #!/bin/bash
    printf '%s\\n' "$*" >> "#{log}"
    if [ "$1" = "is-active" ]; then
      exit #{if unit_active?, do: 0, else: 3}
    fi
    if [ "$1" = "list-unit-files" ]; then
      echo "serviceradar-log-collector.service enabled"
      echo "serviceradar-trapd.service enabled"
      echo "serviceradar-flow-collector.service enabled"
    fi
    exit 0
    """
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp extract_files(tarball) do
    {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

    Map.new(files, fn {name, content} ->
      {to_string(name), IO.iodata_to_binary(content)}
    end)
  end

  defp tar_modes(tarball) do
    {:ok, table} = :erl_tar.table({:binary, tarball}, [:compressed, :verbose])

    Map.new(table, fn {name, :regular, _size, _mtime, mode, _uid, _gid} ->
      relative = name |> to_string() |> String.split("/", parts: 2) |> List.last()
      {relative, Bitwise.band(mode, 0o7777)}
    end)
  end

  defp find_file(files, suffix) do
    Enum.find_value(files, fn {name, content} ->
      if String.ends_with?(name, suffix), do: content
    end)
  end

  defp sample_falcosidekick_package do
    %CollectorPackage{
      id: "12345678-abcd-efgh-ijkl-1234567890ab",
      collector_type: :falcosidekick,
      site: "demo",
      inserted_at: ~U[2026-03-08 12:00:00Z],
      config_overrides: %{
        "namespace" => "demo",
        "release_name" => "falcosidekick-nats-auth"
      }
    }
  end

  defp bundle_subjects do
    netflow = flow_bundle_config(sample_flow_package(:netflow))
    sflow = flow_bundle_config(sample_flow_package(:sflow))
    trapd = bundle_json(sample_flow_package(:trapd), "trapd.json")
    flowgger = bundle_text(sample_flow_package(:flowgger), "flowgger.toml")
    otel = bundle_text(sample_flow_package(:otel), "otel.toml")
    falco = falcosidekick_values(sample_falcosidekick_package())

    [
      {:netflow, netflow["stream_name"], hd(netflow["listeners"])["subject"]},
      {:sflow, sflow["stream_name"], hd(sflow["listeners"])["subject"]},
      {:trapd, trapd["stream_name"], trapd["subject"]},
      {:flowgger, toml_string(flowgger, "nats_stream"), toml_string(flowgger, "nats_subject")},
      {:otel, toml_string(otel, "stream"), toml_string(otel, "logs_subject")},
      {:falcosidekick, "events", falco["config"]["nats"]["subjecttemplate"]}
    ]
  end

  defp falcosidekick_values(package) do
    package |> bundle_text("falcosidekick.yaml") |> YamlElixir.read_from_string!()
  end

  defp captures?(stream, stream_name, subject) do
    Map.get(stream, :ensure_stream, true) and
      EventWriterConfig.jetstream_stream_name(stream) == stream_name and
      nats_covers?(String.split(stream.subject, "."), String.split(subject, "."))
  end

  defp nats_covers?([">"], [_ | _]), do: true
  defp nats_covers?(["*" | filter], [_ | subject]), do: nats_covers?(filter, subject)
  defp nats_covers?([token | filter], [token | subject]), do: nats_covers?(filter, subject)
  defp nats_covers?([], []), do: true
  defp nats_covers?(_filter, _subject), do: false

  defp toml_settings(toml) do
    toml
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
  end

  defp toml_string(toml, key) do
    [_, value] = Regex.run(~r/^#{key} = "([^"]+)"$/m, toml)
    value
  end

  defp bundle_json(package, file), do: package |> bundle_text(file) |> Jason.decode!()

  defp bundle_text(package, file) do
    {:ok, tarball} =
      CollectorBundleGenerator.create_tarball(package, sample_nats_creds(), sample_tls_key(),
        nats_url: "tls://host01.example.com:4222"
      )

    tarball |> extract_files() |> find_file(file)
  end

  defp flow_bundle_config(package), do: bundle_json(package, "flow-collector.json")

  defp sample_flow_package(type, config_overrides \\ %{}) do
    %CollectorPackage{
      id: "11111111-2222-4333-8444-555555555555",
      collector_type: type,
      site: "site01",
      inserted_at: ~U[2026-03-08 12:00:00Z],
      tls_cert_pem: "cert-pem\n",
      ca_chain_pem: "ca-pem\n",
      config_overrides: config_overrides
    }
  end

  defp sample_otel_package(config_overrides \\ %{}) do
    %CollectorPackage{
      id: "87654321-dcba-hgfe-lkji-0987654321ba",
      collector_type: :otel,
      site: "demo",
      inserted_at: ~U[2026-03-08 12:00:00Z],
      tls_cert_pem: "cert-pem\n",
      ca_chain_pem: "ca-pem\n",
      config_overrides: config_overrides
    }
  end

  defp sample_flowgger_package(config_overrides \\ %{}) do
    %CollectorPackage{
      id: "abcdef12-3456-7890-abcd-ef1234567890",
      collector_type: :flowgger,
      site: "SITE01",
      inserted_at: ~U[2030-10-06 03:20:29Z],
      tls_cert_pem: "cert-pem\n",
      ca_chain_pem: "ca-pem\n",
      config_overrides: config_overrides
    }
  end

  defp put_web_ng_env(key, value) do
    previous = Application.get_env(:serviceradar_web_ng, key)
    Application.put_env(:serviceradar_web_ng, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, key, previous),
        else: Application.delete_env(:serviceradar_web_ng, key)
    end)
  end

  defp sample_nats_creds do
    """
    -----BEGIN NATS USER JWT-----
    dGVzdC11c2VyLWp3dA==
    ------END NATS USER JWT------
    """
  end

  defp sample_tls_key do
    """
    -----BEGIN PRIVATE KEY-----
    dGVzdC10bHMta2V5
    -----END PRIVATE KEY-----
    """
  end
end
