defmodule ServiceRadarWebNGWeb.DevRoutesTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  @moduletag :web_ng_shared_fixture_db

  setup do
    previous = Application.fetch_env(:serviceradar_web_ng, :dev_routes)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:serviceradar_web_ng, :dev_routes, value)
        :error -> Application.delete_env(:serviceradar_web_ng, :dev_routes)
      end
    end)
  end

  test "dev routes answer 404 when disabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :dev_routes, false)
    assert conn |> get("/dev/dashboard") |> response(404)
  end

  test "dev routes mount when enabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :dev_routes, true)
    conn = get(conn, "/dev/dashboard")

    case conn.status do
      200 -> assert html_response(conn, 200) =~ "Dashboard"
      302 -> assert redirected_to(conn) =~ ~r{^/dev/dashboard}
    end
  end
end
