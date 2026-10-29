defmodule ServiceRadarWebNGWeb.SecurityHeadersTest do
  use ServiceRadarWebNGWeb.ConnCase

  alias ServiceRadarWebNGWeb.Plugs.SecurityHeaders

  @moduletag :web_ng_shared_fixture_db

  test "browser responses include hardened CSP without unsafe-inline scripts", %{conn: conn} do
    conn = get(conn, ~p"/")

    csp =
      List.first(
        get_resp_header(conn, "content-security-policy") ++ get_resp_header(conn, "content-security-policy-report-only")
      )

    assert csp
    assert csp =~ "script-src 'self' blob:"
    assert csp =~ "media-src blob: mediastream:;"
    refute csp =~ ~r/media-src[^;]*(https:|\*)/
    assert csp =~ "frame-ancestors 'none'"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
  end

  describe "csp_mode" do
    setup do
      previous = Application.get_env(:serviceradar_web_ng, SecurityHeaders, [])

      on_exit(fn ->
        Application.put_env(:serviceradar_web_ng, SecurityHeaders, previous)
      end)
    end

    test ":enforce sends an enforcing CSP header", %{conn: conn} do
      put_csp_mode(:enforce)
      conn = get(conn, ~p"/")

      assert [_] = get_resp_header(conn, "content-security-policy")
      assert [] = get_resp_header(conn, "content-security-policy-report-only")
    end

    test ":report_only sends a report-only CSP header", %{conn: conn} do
      put_csp_mode(:report_only)
      conn = get(conn, ~p"/")

      assert [_] = get_resp_header(conn, "content-security-policy-report-only")
      assert [] = get_resp_header(conn, "content-security-policy")
    end
  end

  defp put_csp_mode(mode) do
    config = Application.get_env(:serviceradar_web_ng, SecurityHeaders, [])

    Application.put_env(
      :serviceradar_web_ng,
      SecurityHeaders,
      Keyword.put(config, :csp_mode, mode)
    )
  end
end
