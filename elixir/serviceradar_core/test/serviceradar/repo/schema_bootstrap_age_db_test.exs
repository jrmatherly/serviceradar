defmodule ServiceRadar.Repo.SchemaBootstrapAgeDbTest do
  use ExUnit.Case, async: false

  import ServiceRadar.TestSupport, only: [checkout_repo!: 1]

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.SchemaBootstrap

  # Unboxed: a graph is real DDL plus a row in AGE's catalog.
  @moduletag :database
  @moduletag sandbox: :unboxed

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup :checkout_repo!

  setup do
    graph = "test_baseline_graph_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if registered?(graph) do
        Repo.query!("SELECT ag_catalog.drop_graph('#{graph}', true)")
      else
        Repo.query!(~s(DROP SCHEMA IF EXISTS "#{graph}" CASCADE))
      end
    end)

    {:ok, graph: graph}
  end

  defp registered?(graph) do
    %{rows: [[found?]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name::text = $1)", [
        graph
      ])

    found?
  end

  test "a schema the baseline left without a catalog row becomes a real graph", %{graph: graph} do
    Repo.query!(~s(CREATE SCHEMA "#{graph}"))
    refute registered?(graph)

    assert :ok = SchemaBootstrap.register_age_graphs!(Repo, [graph])

    assert registered?(graph)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM ag_catalog.cypher('#{graph}', $$
             MATCH (n) RETURN n $$) AS (n ag_catalog.agtype)")
  end

  test "a registered graph keeps its data", %{graph: graph} do
    Repo.query!("SELECT ag_catalog.create_graph('#{graph}')")

    Repo.query!(
      "SELECT count(*) FROM ag_catalog.cypher('#{graph}', $$ CREATE (:Kept) $$) AS (n ag_catalog.agtype)"
    )

    assert :ok = SchemaBootstrap.register_age_graphs!(Repo, [graph])

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM ag_catalog.cypher('#{graph}', $$
             MATCH (n:Kept) RETURN n $$) AS (n ag_catalog.agtype)")
  end

  test "the canonical rebuild can read a graph no mapper has written to" do
    assert {:ok, _} = Repo.query(CanonicalRebuild.rebuild_input_fingerprint_query())
  end

  test "a graph with no schema at all is left absent", %{graph: graph} do
    assert :ok = SchemaBootstrap.register_age_graphs!(Repo, [graph])
    refute registered?(graph)
  end
end
