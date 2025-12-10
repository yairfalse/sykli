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

  # ----- MATRIX EXPANSION TESTS -----

  test "expand_matrix with no matrix returns unchanged" do
    json = ~s({"tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)
    assert Map.has_key?(expanded, "test")
    assert map_size(expanded) == 1
  end

  test "expand_matrix single dimension" do
    json = ~s({"tasks":[{"name":"test","command":"go test","matrix":{"version":["1.0","2.0"]}}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    # Should have 2 expanded tasks
    assert map_size(expanded) == 2
    assert Map.has_key?(expanded, "test-1.0")
    assert Map.has_key?(expanded, "test-2.0")

    # Original task should be gone
    refute Map.has_key?(expanded, "test")
  end

  test "expand_matrix multi-dimensional" do
    json = ~s({"tasks":[{"name":"test","command":"go test","matrix":{"os":["linux","macos"],"version":["1.0","2.0"]}}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    # Should have 4 expanded tasks (2x2)
    assert map_size(expanded) == 4
  end

  test "expand_matrix injects values into env" do
    json = ~s({"tasks":[{"name":"test","command":"go test","matrix":{"version":["1.0"]}}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    task = Map.get(expanded, "test-1.0")
    assert task.env["version"] == "1.0"
  end

  test "expand_matrix updates dependencies" do
    json = ~s({"tasks":[
      {"name":"test","command":"go test","matrix":{"v":["1","2"]}},
      {"name":"build","command":"go build","depends_on":["test"]}
    ]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    # Build should now depend on both expanded test tasks
    build = Map.get(expanded, "build")
    assert "test-1" in build.depends_on
    assert "test-2" in build.depends_on
  end

  test "expand_matrix with empty matrix returns task unchanged" do
    json = ~s({"tasks":[{"name":"test","command":"go test","matrix":{}}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)
    assert Map.has_key?(expanded, "test")
    assert map_size(expanded) == 1
  end

  # ----- CONDITION PARSING TESTS -----

  test "parses when condition from JSON" do
    json = ~s({"tasks":[{"name":"deploy","command":"./deploy.sh","when":"branch == 'main'"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.condition == "branch == 'main'"
  end

  test "when condition is nil when not set" do
    json = ~s({"tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.condition == nil
  end

  # ----- SECRETS PARSING TESTS -----

  test "parses secrets from JSON" do
    json = ~s({"tasks":[{"name":"deploy","command":"./deploy.sh","secrets":["GITHUB_TOKEN","NPM_TOKEN"]}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.secrets == ["GITHUB_TOKEN", "NPM_TOKEN"]
  end

  test "secrets is empty list when not set" do
    json = ~s({"tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.secrets == []
  end

  # ----- SERVICES PARSING TESTS -----

  test "parses services from JSON" do
    json = ~s({"tasks":[{"name":"test","command":"go test","services":[{"image":"postgres:15","name":"db"}]}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert length(task.services) == 1
    assert hd(task.services).image == "postgres:15"
    assert hd(task.services).name == "db"
  end

  test "services is empty list when not set" do
    json = ~s({"tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.services == []
  end

  test "parses multiple services" do
    json = ~s({"tasks":[{"name":"test","command":"go test","services":[{"image":"postgres:15","name":"db"},{"image":"redis:7","name":"cache"}]}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert length(task.services) == 2
  end

  # ----- ADDITIONAL MATRIX TESTS -----

  test "expand_matrix preserves matrix_values for expanded tasks" do
    json = ~s({"tasks":[{"name":"test","command":"go test","matrix":{"os":["linux"],"ver":["1.0"]}}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    # Find the expanded task
    task = expanded |> Map.values() |> hd()
    assert task.matrix_values != nil
    assert task.matrix_values["os"] == "linux"
    assert task.matrix_values["ver"] == "1.0"
  end

  test "expand_matrix with nil matrix returns task unchanged" do
    json = ~s({"tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)
    assert Map.has_key?(expanded, "test")
    task = Map.get(expanded, "test")
    assert task.matrix == nil
  end

  # ----- CONDITION EDGE CASES -----

  test "parses legacy 'condition' field" do
    json = ~s({"tasks":[{"name":"deploy","command":"./deploy.sh","condition":"branch == 'main'"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.condition == "branch == 'main'"
  end

  test "when field takes precedence over condition field" do
    json = ~s({"tasks":[{"name":"deploy","command":"./deploy.sh","when":"tag != ''","condition":"branch == 'main'"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.condition == "tag != ''"
  end

  # ----- SERVICE VALIDATION -----

  test "services parses image and name correctly" do
    json = ~s({"tasks":[{"name":"test","command":"test","services":[{"image":"postgres:15","name":"db"}]}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    service = hd(task.services)
    assert service.image == "postgres:15"
    assert service.name == "db"
  end
end
