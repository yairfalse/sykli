defmodule SykliTest do
  use ExUnit.Case

  test "parses task graph" do
    json = ~s({"tasks":[{"name":"test","command":"go test ./..."}]})
    assert {:ok, graph} = Sykli.Graph.parse(json)
    assert Map.has_key?(graph, "test")
  end

  test "topo sort with no deps" do
    json = ~s({"tasks":[{"name":"a","command":"a"},{"name":"b","command":"b"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    {:ok, order} = Sykli.Graph.topo_sort(graph)
    assert length(order) == 2
  end
end
