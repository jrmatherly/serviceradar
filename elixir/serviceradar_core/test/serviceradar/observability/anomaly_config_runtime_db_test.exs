defmodule ServiceRadar.Observability.AnomalyConfigRuntimeDbTest do
  # Serial: the runtime writes its cache to :persistent_term.
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Repo

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  # The runtime starts before the delayed seeder on a fresh database.
  test "missing singletons read as unseeded, not as a refresh failure" do
    Repo.query!("DELETE FROM platform.anomaly_detection_configs")
    Repo.query!("DELETE FROM platform.capacity_forecast_configs")

    log =
      capture_log(fn ->
        start_supervised!(
          {AnomalyConfigRuntime, name: :"#{__MODULE__}.Runtime", refresh_interval_ms: 60_000}
        )
      end)

    refute log =~ "Failed to refresh"
  end
end
