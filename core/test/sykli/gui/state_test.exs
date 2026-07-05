defmodule Sykli.Gui.StateTest do
  use ExUnit.Case, async: true

  alias Sykli.Gui.State

  test "to_wire camelizes keys and drops nil fields" do
    state = Sykli.Gui.Provider.Demo.state([])
    wire = State.to_wire(state)

    assert %{"repo" => repo, "latestRun" => run, "workItems" => [item | _]} = wire
    assert repo["name"] == "false-systems/sykli"
    assert run["primaryFailureNodeId"] == "test:unit"
    assert item["runList"] =~ "#41 failed"

    # nil fields never cross the wire
    refute Map.has_key?(run, "startedAt")
    [format | _] = wire["graph"]["nodes"]
    refute Map.has_key?(format, "failureClass")
  end

  test "v5 fields cross the wire when present" do
    wire = State.to_wire(Sykli.Gui.Provider.Demo.state([]))

    test_unit = Enum.find(wire["graph"]["nodes"], &(&1["id"] == "test:unit"))
    assert test_unit["mandateOutcome"] == "kept"

    codex = Enum.find(wire["members"], &(&1["id"] == "codex"))
    assert codex["mandate"]["budget"]["diffLines"] == 200
    assert codex["mandate"]["network"] == false

    run42 = Enum.find(wire["evidence"], &(&1["runId"] == "run-42"))
    assert run42["auditVerdict"] == "pass"

    # and stay absent when not declared
    run40 = Enum.find(wire["evidence"], &(&1["runId"] == "run-40"))
    refute Map.has_key?(run40, "auditVerdict")
  end

  test "wire document is JSON-encodable" do
    assert {:ok, _json} =
             Sykli.Gui.Provider.Demo.state([]) |> State.to_wire() |> Jason.encode()
  end
end
