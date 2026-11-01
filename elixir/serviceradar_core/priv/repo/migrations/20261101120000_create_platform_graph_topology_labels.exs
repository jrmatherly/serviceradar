defmodule ServiceRadar.Repo.Migrations.CreatePlatformGraphTopologyLabels do
  @moduledoc """
  Creates the labels the canonical topology rebuild reads as tables.

  AGE creates a label on first use, and the rebuild selects from these with SQL, so on
  a graph no mapper has written to yet the rebuild failed on a missing relation.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      label text;
    BEGIN
      PERFORM set_config('search_path', 'ag_catalog,platform,"$user",public', true);

      FOREACH label IN ARRAY ARRAY['CONNECTS_TO', 'LOGICAL_PEER', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO'] LOOP
        IF NOT EXISTS (
          SELECT 1
          FROM ag_catalog.ag_label l
          JOIN ag_catalog.ag_graph g ON g.graphid = l.graph
          WHERE g.name::text = 'platform_graph' AND l.name::text = label
        ) THEN
          -- A literal, because create_elabel takes no text argument.
          EXECUTE format('SELECT ag_catalog.create_elabel(%L, %L)', 'platform_graph', label);
        END IF;
      END LOOP;

      IF NOT EXISTS (
        SELECT 1
        FROM ag_catalog.ag_label l
        JOIN ag_catalog.ag_graph g ON g.graphid = l.graph
        WHERE g.name::text = 'platform_graph' AND l.name::text = 'Interface'
      ) THEN
        PERFORM ag_catalog.create_vlabel('platform_graph', 'Interface');
      END IF;
    END
    $$;
    """)
  end

  # Empty label tables are harmless, and a mapper may have written to them since.
  def down, do: :ok
end
