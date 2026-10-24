defmodule ServiceRadarWebNG.Edge.ComponentIDTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Edge.ComponentID

  @moduletag :db_free

  test "prefixes labels that do not already include the component type" do
    assert ComponentID.generate("Production Gateway 01", "gateway") ==
             "gateway-production-gateway-01"
  end

  test "preserves an existing component-type prefix" do
    assert ComponentID.generate("agent-alpha", "agent") == "agent-alpha"
  end

  test "normalizes mixed-case labels before checking the prefix" do
    assert ComponentID.generate("Agent Alpha", :agent) == "agent-alpha"
  end
end
