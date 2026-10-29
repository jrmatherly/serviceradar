defmodule ServiceRadarWebNGWeb.Plugs.SecurityHeadersEnvTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Plugs.SecurityHeaders

  @moduletag :db_free

  test "maps SERVICERADAR_CSP_MODE values to a CSP mode" do
    assert SecurityHeaders.csp_mode_from_env("enforce") == :enforce
    assert SecurityHeaders.csp_mode_from_env("report-only") == :report_only
    assert SecurityHeaders.csp_mode_from_env(nil) == :report_only
  end

  test "rejects an unknown value instead of falling back" do
    assert_raise ArgumentError, ~r/SERVICERADAR_CSP_MODE/, fn ->
      SecurityHeaders.csp_mode_from_env("enforced")
    end
  end
end
