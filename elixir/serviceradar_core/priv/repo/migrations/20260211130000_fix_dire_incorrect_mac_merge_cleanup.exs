defmodule ServiceRadar.Repo.Migrations.FixDireIncorrectMacMergeCleanup do
  @moduledoc """
  Data cleanup migration for the DIRE incorrect MAC merge bug (#2780).

  Reclassifies locally-administered MAC identifiers from 'strong' to 'medium'
  confidence. Such MACs are assigned by software, so two unrelated devices can
  report the same one and a 'strong' match merged them. Rows a past merge
  misattributed on a particular database are repaired with `unmerge_device`,
  not here.
  """

  use Ecto.Migration

  def up do
    # IEEE locally-administered: bit 1 of the first octet is set, so the second
    # hex digit of the first octet pair is one of 2,3,6,7,A,B,E,F.
    execute """
    UPDATE platform.device_identifiers
    SET confidence = 'medium',
        last_seen = NOW()
    WHERE identifier_type = 'mac'
      AND confidence = 'strong'
      AND (
        substring(identifier_value, 2, 1) IN ('2','3','6','7','A','B','E','F','a','b','e','f')
      )
    """
  end

  def down do
    # Data cleanup is not reversible; the unmerge_device function provides the
    # proper mechanism for reversal if needed.
    :ok
  end
end
