defmodule ServiceRadarWebNG.FieldSurveyRoomArtifactsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.FieldSurveyRoomArtifacts

  @moduletag :db_free

  test "each allowlisted artifact type maps to its extension and Content-Type" do
    assert FieldSurveyRoomArtifacts.format("roomplan_usdz") == {"usdz", "model/vnd.usdz+zip"}
    assert FieldSurveyRoomArtifacts.format("floorplan_geojson") == {"geojson", "application/geo+json"}
    assert FieldSurveyRoomArtifacts.format("point_cloud_ply") == {"ply", "application/octet-stream"}
  end

  test "an unknown artifact type downloads as opaque bytes, never as a renderable type" do
    assert FieldSurveyRoomArtifacts.format("text/html") == {"bin", "application/octet-stream"}
    assert FieldSurveyRoomArtifacts.format("legacy_scan") == {"bin", "application/octet-stream"}
  end
end
