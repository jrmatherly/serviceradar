defmodule ServiceRadar.Inventory.IntegrationIdentityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.IntegrationIdentity

  @edge_integration_id "11111111-1111-4111-8111-111111111111"
  @edge_controller_id "22222222-2222-4222-8222-222222222222"
  @hub_integration_id "33333333-3333-4333-8333-333333333333"
  @hub_controller_id "44444444-4444-4444-8444-444444444444"

  @tag :scoped_identity_contract
  test "scoped device identities normalize source boundaries and retain native IDs" do
    assert IntegrationIdentity.scoped_device_id("armis", " : SOURCE : A : ", "101") ==
             "armis:source-a:device:101"

    assert IntegrationIdentity.scoped_device_id("netbox", "Source B", "101") ==
             "netbox:source-b:device:101"

    assert IntegrationIdentity.scoped_device_id("armis", nil, "101") == nil
    assert IntegrationIdentity.scoped_device_id("armis", " : ", "101") == nil

    refute IntegrationIdentity.scoped_device_id("armis", "source-a", "101") ==
             IntegrationIdentity.scoped_device_id("armis", "source-b", "101")
  end

  describe "proxmox v3 source-scoped identities" do
    test "renders and parses canonical cluster, node, and guest refs" do
      assert {:ok, cluster} =
               IntegrationIdentity.proxmox_v3_fields(
                 @edge_integration_id,
                 @edge_controller_id,
                 "cluster/edge 01",
                 :cluster,
                 "cluster/edge 01"
               )

      assert cluster.provider_instance_ref ==
               "proxmox:v3:#{@edge_integration_id}:#{@edge_controller_id}:cluster%2Fedge%2001"

      assert cluster.provider_ref ==
               "#{cluster.provider_instance_ref}:cluster:cluster%2Fedge%2001"

      assert {:ok, node} =
               IntegrationIdentity.proxmox_v3_fields(
                 @edge_integration_id,
                 @edge_controller_id,
                 "cluster/edge 01",
                 :node,
                 "pve:a"
               )

      assert node.provider_ref == "#{cluster.provider_instance_ref}:node:pve%3Aa"
      assert {:ok, ^node} = IntegrationIdentity.parse_v3(node.provider_ref)
      assert IntegrationIdentity.v3?(node.provider_ref)

      assert {:ok, guest} =
               IntegrationIdentity.proxmox_v3_fields(
                 @edge_integration_id,
                 @edge_controller_id,
                 "cluster/edge 01",
                 :vm,
                 "00100"
               )

      assert guest.object_kind == "qemu"
      assert guest.native_object_id == "100"
      assert guest.provider_ref == "#{cluster.provider_instance_ref}:qemu:100"
    end

    test "keeps identical native identifiers distinct across integration/controller scopes" do
      assert {:ok, edge} =
               IntegrationIdentity.proxmox_v3_fields(
                 @edge_integration_id,
                 @edge_controller_id,
                 "lab",
                 :qemu,
                 155
               )

      assert {:ok, hub} =
               IntegrationIdentity.proxmox_v3_fields(
                 @hub_integration_id,
                 @hub_controller_id,
                 "lab",
                 :qemu,
                 155
               )

      refute edge.provider_instance_ref == hub.provider_instance_ref
      refute edge.provider_ref == hub.provider_ref
      assert edge.native_cluster_id == hub.native_cluster_id
      assert edge.native_object_id == hub.native_object_id
    end

    test "rejects malformed, noncanonical, and mismatched structured refs" do
      assert {:error, :invalid_uuid} =
               IntegrationIdentity.proxmox_v3_fields(
                 "edge01",
                 @edge_controller_id,
                 "lab",
                 :node,
                 "pve01"
               )

      refute IntegrationIdentity.v3?(
               "proxmox:v3:#{@edge_integration_id}:#{@edge_controller_id}:lab:node:pve%30%31"
             )

      assert {:ok, identity} =
               IntegrationIdentity.proxmox_v3_fields(
                 @edge_integration_id,
                 @edge_controller_id,
                 "lab",
                 :node,
                 "pve01"
               )

      assert :ok = IntegrationIdentity.validate_v3_record(identity)

      assert {:error, :invalid_proxmox_v3_identity} =
               identity
               |> Map.put(:native_object_id, "pve02")
               |> IntegrationIdentity.validate_v3_record()

      assert {:error, :invalid_proxmox_v3_identity} =
               IntegrationIdentity.validate_v3_record(%{
                 provider_ref: identity.provider_ref,
                 identity_version: 3
               })
    end

    test "returns v2 and older refs only as lookup candidates" do
      assert {:ok, identity} =
               IntegrationIdentity.proxmox_v3_fields(
                 @edge_integration_id,
                 @edge_controller_id,
                 "cluster/edge01",
                 :qemu,
                 132
               )

      candidates =
        IntegrationIdentity.legacy_candidates(identity.provider_ref, %{
          node: "pve01",
          name: "alpha01",
          guest_type: "qemu"
        })

      assert "proxmox:v2:edge01:vm:132" in candidates
      refute "proxmox:guest:pve01:qemu:132" in candidates
      # bare guest names never bridge: alpha01 may name a different cluster's VM
      refute "proxmox:vm:alpha01" in candidates
      refute identity.provider_ref in candidates
    end
  end

  describe "proxmox_node_id/2" do
    test "mints the versioned cluster-scoped node id" do
      assert IntegrationIdentity.proxmox_node_id("edge01", "pve01") ==
               "proxmox:v2:edge01:node:pve01"
    end

    test "normalizes segments so case/format churn cannot rotate the id" do
      assert IntegrationIdentity.proxmox_node_id(" Edge01 ", "PVE01") ==
               "proxmox:v2:edge01:node:pve01"

      assert IntegrationIdentity.proxmox_node_id("lab cluster", "node:a") ==
               "proxmox:v2:lab-cluster:node:node-a"
    end

    test "returns nil when either segment is missing" do
      assert IntegrationIdentity.proxmox_node_id(nil, "pve01") == nil
      assert IntegrationIdentity.proxmox_node_id("edge01", nil) == nil
      assert IntegrationIdentity.proxmox_node_id("  ", "pve01") == nil
      assert IntegrationIdentity.proxmox_node_id("edge01", "") == nil
    end
  end

  describe "proxmox_guest_id/3" do
    test "mints vmid-keyed guest ids for qemu and lxc" do
      assert IntegrationIdentity.proxmox_guest_id("edge01", "qemu", 132) ==
               "proxmox:v2:edge01:vm:132"

      assert IntegrationIdentity.proxmox_guest_id("edge01", "lxc", 201) ==
               "proxmox:v2:edge01:lxc:201"
    end

    test "accepts already-normalized kinds and string vmids" do
      assert IntegrationIdentity.proxmox_guest_id("edge01", "vm", "132") ==
               "proxmox:v2:edge01:vm:132"

      assert IntegrationIdentity.proxmox_guest_id("edge01", "container", 201) ==
               "proxmox:v2:edge01:lxc:201"
    end

    test "returns nil when cluster, kind, or vmid are unusable" do
      assert IntegrationIdentity.proxmox_guest_id(nil, "qemu", 132) == nil
      assert IntegrationIdentity.proxmox_guest_id("edge01", nil, 132) == nil
      assert IntegrationIdentity.proxmox_guest_id("edge01", "qemu", nil) == nil
      assert IntegrationIdentity.proxmox_guest_id("edge01", "qemu", "abc") == nil
      assert IntegrationIdentity.proxmox_guest_id("edge01", "qemu", -1) == nil
    end
  end

  describe "v2?/1 and parse_v2/1" do
    test "recognizes v2 ids" do
      assert IntegrationIdentity.v2?("proxmox:v2:edge01:vm:132")
      refute IntegrationIdentity.v2?("proxmox:vm:alpha01")
      refute IntegrationIdentity.v2?(nil)
      refute IntegrationIdentity.v2?(132)
    end

    test "parses v2 ids into components" do
      assert {:ok, %{provider: "proxmox", cluster: "edge01", kind: "vm", ref: "132"}} =
               IntegrationIdentity.parse_v2("proxmox:v2:edge01:vm:132")

      assert {:ok, %{cluster: "edge01", kind: "node", ref: "pve01"}} =
               IntegrationIdentity.parse_v2("proxmox:v2:edge01:node:pve01")

      assert :error = IntegrationIdentity.parse_v2("proxmox:v2:edge01:vm")
      assert :error = IntegrationIdentity.parse_v2("proxmox:vm:alpha01")
      assert :error = IntegrationIdentity.parse_v2(nil)
    end
  end

  describe "legacy_candidates/2 for guests" do
    test "never bridges across clusters through shared guest attributes" do
      fields = %{
        name: "guest01.example.com",
        node: "host01.example.com",
        guest_type: "qemu",
        guest_id: "qemu/901",
        macs: ["00:00:5e:00:53:21"]
      }

      assert IntegrationIdentity.legacy_candidates("proxmox:v2:cluster-a:vm:901", fields) == []
      assert IntegrationIdentity.legacy_candidates("proxmox:v2:cluster-b:vm:901", fields) == []
      assert IntegrationIdentity.legacy_candidates("proxmox:v2:cluster-a:lxc:902", fields) == []
    end
  end

  describe "legacy_candidates/2 for nodes" do
    # Every node legacy form is a bare name (`proxmox:node:<name>`,
    # `proxmox:pve:<name>`, `proxmox:hypervisor:<name>`), and node names are
    # reused across clusters — so none of them bridge (GitHub #4051 fused
    # pve01/pve02 across clusters via the hypervisor form). Node convergence
    # continues through the v2 id, the exact provider ref, host NIC MACs, and
    # the IP/hostname adopt/merge rules.
    test "emits no bare-name bridges" do
      assert IntegrationIdentity.legacy_candidates("proxmox:v2:edge01:node:pve01", %{
               name: "pve01"
             }) == []

      assert IntegrationIdentity.legacy_candidates("proxmox:v2:edge01:node:pve01", %{
               name: "pve01.example.com"
             }) == []
    end

    test "v3 node refs still bridge to their v2 id" do
      assert {:ok, identity} =
               IntegrationIdentity.proxmox_v3_fields(
                 @edge_integration_id,
                 @edge_controller_id,
                 "cluster/edge01",
                 :node,
                 "pve01"
               )

      candidates = IntegrationIdentity.legacy_candidates(identity.provider_ref, %{})
      assert candidates == ["proxmox:v2:edge01:node:pve01"]
    end
  end

  describe "ambiguous_name_keyed?/1" do
    test "flags the bare-name legacy family" do
      assert IntegrationIdentity.ambiguous_name_keyed?("proxmox:vm:lab-k8s-worker1")
      assert IntegrationIdentity.ambiguous_name_keyed?("proxmox:container:traefik")
      assert IntegrationIdentity.ambiguous_name_keyed?("proxmox:hypervisor:pve01")
      assert IntegrationIdentity.ambiguous_name_keyed?("proxmox:node:pve01")
      assert IntegrationIdentity.ambiguous_name_keyed?("proxmox:pve:pve02")
    end

    test "requires cluster scope for every Proxmox identifier" do
      refute IntegrationIdentity.ambiguous_name_keyed?("proxmox:v2:cluster-a:vm:901")

      for value <- [
            "proxmox:vm:901",
            "proxmox:vm:qemu/901",
            "proxmox:guest:host01.example.com:qemu:901",
            "proxmox:qemu:host01.example.com:901",
            "proxmox:lxc:902",
            "proxmox:vm:00:00:5e:00:53:21",
            "proxmox:v2::vm:901",
            "proxmox:vm:"
          ] do
        assert IntegrationIdentity.ambiguous_name_keyed?(value)
      end
    end

    test "ignores other sources and non-strings" do
      for value <- ["netbox:device:42", "armis:123", nil, 132, ""] do
        refute IntegrationIdentity.ambiguous_name_keyed?(value)
      end
    end

    test "matches case-insensitively with surrounding whitespace" do
      assert IntegrationIdentity.ambiguous_name_keyed?("  PROXMOX:VM:LAB-K8S-Worker1  ")
    end
  end

  describe "legacy_candidates/2 edge cases" do
    test "returns no candidates for non-v2 or missing ids" do
      assert IntegrationIdentity.legacy_candidates("proxmox:vm:alpha01", %{name: "alpha01"}) == []
      assert IntegrationIdentity.legacy_candidates(nil, %{name: "alpha01"}) == []
      assert IntegrationIdentity.legacy_candidates("proxmox:v2:bad", %{}) == []
    end

    test "deduplicates and drops blank values" do
      candidates =
        IntegrationIdentity.legacy_candidates("proxmox:v2:edge01:vm:132", %{
          name: "  ",
          node: "pve01",
          guest_type: "qemu"
        })

      assert candidates == Enum.uniq(candidates)
      refute Enum.any?(candidates, &(String.trim(&1) == ""))
      refute Enum.any?(candidates, &String.ends_with?(&1, ":"))
    end
  end

  describe "lookup_values/1" do
    test "returns the canonical id first and legacy bridges last" do
      assert IntegrationIdentity.lookup_values(%{
               integration_id: "proxmox:v2:edge01:vm:132",
               legacy_integration_ids: ["proxmox:vm:alpha01", "proxmox:vm:qemu/132"]
             }) == [
               "proxmox:v2:edge01:vm:132",
               "proxmox:vm:alpha01",
               "proxmox:vm:qemu/132"
             ]
    end

    test "accepts string keys, list primaries, and deduplicates" do
      assert IntegrationIdentity.lookup_values(%{
               "integration_id" => ["proxmox:v2:edge01:vm:132", "proxmox:guest:pve01:qemu:132"],
               "legacy_integration_ids" => ["proxmox:guest:pve01:qemu:132", "", nil]
             }) == [
               "proxmox:v2:edge01:vm:132",
               "proxmox:guest:pve01:qemu:132"
             ]
    end

    test "handles missing keys and non-map input" do
      assert IntegrationIdentity.lookup_values(%{integration_id: "proxmox:v2:c:vm:1"}) ==
               ["proxmox:v2:c:vm:1"]

      assert IntegrationIdentity.lookup_values(%{}) == []
      assert IntegrationIdentity.lookup_values(nil) == []
    end
  end
end
