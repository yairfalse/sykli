defmodule SykliTest do
  use ExUnit.Case

  test "parses task graph" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test ./..."}]})
    assert {:ok, graph} = Sykli.Graph.parse(json)
    assert Map.has_key?(graph, "test")
  end

  test "accepts each supported contract schema version" do
    for version <- Sykli.ContractSchemaVersion.supported_versions() do
      json = ~s({"version":"#{version}","tasks":[{"name":"test","command":"go test ./..."}]})
      assert {:ok, graph} = Sykli.Graph.parse(json)
      assert Map.has_key?(graph, "test")
    end
  end

  test "rejects missing contract schema version" do
    json = ~s({"tasks":[{"name":"test","command":"go test ./..."}]})
    assert {:error, :missing_contract_schema_version} = Sykli.Graph.parse(json)
  end

  test "rejects malformed and unsupported contract schema versions" do
    cases = [
      {~s({"version":null,"tasks":[{"name":"test","command":"go test ./..."}]}),
       {:invalid_contract_schema_version_type, nil}},
      {~s({"version":"","tasks":[{"name":"test","command":"go test ./..."}]}),
       :empty_contract_schema_version},
      {~s({"version":"   ","tasks":[{"name":"test","command":"go test ./..."}]}),
       :empty_contract_schema_version},
      {~s({"version":1,"tasks":[{"name":"test","command":"go test ./..."}]}),
       {:invalid_contract_schema_version_type, 1}},
      {~s({"version":0.1,"tasks":[{"name":"test","command":"go test ./..."}]}),
       {:invalid_contract_schema_version_type, 0.1}},
      {~s({"version":true,"tasks":[{"name":"test","command":"go test ./..."}]}),
       {:invalid_contract_schema_version_type, true}},
      {~s({"version":[],"tasks":[{"name":"test","command":"go test ./..."}]}),
       {:invalid_contract_schema_version_type, []}},
      {~s({"version":{},"tasks":[{"name":"test","command":"go test ./..."}]}),
       {:invalid_contract_schema_version_type, %{}}},
      {~s({"version":"0.2","tasks":[{"name":"test","command":"go test ./..."}]}),
       {:unsupported_contract_schema_version, "0.2"}},
      {~s({"version":"1.0","tasks":[{"name":"test","command":"go test ./..."}]}),
       {:unsupported_contract_schema_version, "1.0"}},
      {~s({"version":"banana","tasks":[{"name":"test","command":"go test ./..."}]}),
       {:unsupported_contract_schema_version, "banana"}}
    ]

    for {json, expected_error} <- cases do
      assert {:error, ^expected_error} = Sykli.Graph.parse(json)
    end
  end

  test "formats contract schema version parse errors" do
    assert Sykli.Graph.format_error(:missing_contract_schema_version) ==
             "Error: missing contract schema version"

    assert Sykli.Graph.format_error({:invalid_contract_schema_version_type, 1}) ==
             "Error: invalid contract schema version: expected string, got integer"

    assert Sykli.Graph.format_error(:empty_contract_schema_version) ==
             "Error: empty contract schema version"

    assert Sykli.Graph.format_error({:unsupported_contract_schema_version, "0.2"}) ==
             "Error: unsupported contract schema version: 0.2; supported versions: 1, 2, 3, 4, 5"
  end

  test "parses task_type on version 3 executable tasks" do
    json =
      ~s({"version":"3","tasks":[{"name":"test","command":"go test ./...","task_type":"test"}]})

    assert {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.fetch!(graph, "test")
    assert Sykli.Graph.Task.task_type(task) == "test"
  end

  test "rejects task_type before version 3" do
    json =
      ~s({"version":"2","tasks":[{"name":"test","command":"go test ./...","task_type":"test"}]})

    assert {:error, {:task_type_requires_v3_or_newer, "test", "2", "test"}} =
             Sykli.Graph.parse(json)
  end

  test "rejects unknown task_type" do
    json = ~s({"version":"3","tasks":[{"name":"thing","command":"echo hi","task_type":"custom"}]})
    assert {:error, {:unknown_task_type, "thing", "custom"}} = Sykli.Graph.parse(json)
  end

  test "rejects task_type on review nodes" do
    json =
      ~s({"version":"3","tasks":[{"name":"review-code","kind":"review","primitive":"lint","task_type":"lint"}]})

    assert {:error, {:task_type_on_review, "review-code"}} = Sykli.Graph.parse(json)
  end

  test "formats task_type parse errors" do
    assert Sykli.Graph.format_error({:task_type_on_review, "review-code"}) ==
             "Error: Review node 'review-code' cannot declare task_type"

    assert Sykli.Graph.format_error({:task_type_requires_v3_or_newer, "test", "2", "test"}) ==
             ~s(Error: Task 'test' declares task_type but pipeline version is "2", not "3" or newer)

    assert Sykli.Graph.format_error({:unknown_task_type, "thing", "custom"}) ==
             ~s(Error: Task 'thing' declares unknown task_type "custom")
  end

  test "rejects evidence_required on review nodes" do
    json =
      ~s({"version":"4","tasks":[{"name":"review-code","kind":"review","primitive":"lint","evidence_required":[{"type":"file","name":"coverage","ref_pattern":"coverage.out"}]}]})

    assert {:error, {:evidence_required_on_review, "review-code"}} = Sykli.Graph.parse(json)
  end

  test "parses review nodes with metadata" do
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"go test ./..."},{"name":"review:api-breakage","kind":"review","primitive":"api-breakage","agent":"local","inputs":["main...HEAD"],"context":["README.md","docs/architecture.md"],"outputs":["reviews/api-breakage.local.json"],"depends_on":["test"],"deterministic":false}]})

    assert {:ok, graph} = Sykli.Graph.parse(json)
    review = Map.fetch!(graph, "review:api-breakage")

    assert Sykli.Graph.Task.review?(review)
    assert Sykli.Graph.Task.kind(review) == :review
    assert Sykli.Graph.Task.primitive(review) == "api-breakage"
    assert Sykli.Graph.Task.agent(review) == "local"
    assert Sykli.Graph.Task.inputs(review) == ["main...HEAD"]
    assert Sykli.Graph.Task.context(review) == ["README.md", "docs/architecture.md"]
    assert Sykli.Graph.Task.outputs(review) == ["reviews/api-breakage.local.json"]
    assert Sykli.Graph.Task.depends_on(review) == ["test"]
    refute Sykli.Graph.Task.deterministic?(review)
    refute Sykli.Graph.Task.cacheable?(review)
  end

  test "topo sort with no deps" do
    json = ~s({"version":"1","tasks":[{"name":"a","command":"a"},{"name":"b","command":"b"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    {:ok, order} = Sykli.Graph.topo_sort(graph)
    assert length(order) == 2
  end

  test "topo sort preserves exact Kahn FIFO output order (#242)" do
    # Locks the "identical output order" guarantee of the linear rewrite. For a
    # diamond a -> {b, c} -> d with <=32 nodes (key-sorted map iteration), Kahn's
    # algorithm yields exactly [a, b, c, d]: a is the only root; processing it
    # enqueues its dependents b, c in graph order; d is enqueued only once both
    # b and c are drained.
    json =
      ~s({"version":"1","tasks":[) <>
        ~s({"name":"a","command":"a"},) <>
        ~s({"name":"b","command":"b","depends_on":["a"]},) <>
        ~s({"name":"c","command":"c","depends_on":["a"]},) <>
        ~s({"name":"d","command":"d","depends_on":["b","c"]}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    {:ok, order} = Sykli.Graph.topo_sort(graph)

    assert Enum.map(order, & &1.name) == ["a", "b", "c", "d"]
  end

  test "topo sort returns a valid order for a large dense layered graph (#242)" do
    # Layered DAG: every node in a layer depends on every node in the previous
    # layer (dense fan-in/out). Exercises the reverse-adjacency + FIFO path at a
    # scale where the old per-dequeue full-graph rescan would be quadratic.
    layers = 30
    width = 20

    tasks =
      for l <- 0..(layers - 1), w <- 0..(width - 1) do
        deps = if l == 0, do: [], else: for(pw <- 0..(width - 1), do: "l#{l - 1}_n#{pw}")
        %Sykli.Graph.Task{name: "l#{l}_n#{w}", command: "true", depends_on: deps}
      end

    graph = Map.new(tasks, fn t -> {t.name, t} end)

    assert {:ok, order} = Sykli.Graph.topo_sort(graph)
    assert length(order) == layers * width

    # Validity: every task appears strictly after all of its dependencies.
    positions = order |> Enum.with_index() |> Map.new(fn {t, i} -> {t.name, i} end)

    for t <- order, dep <- t.depends_on do
      assert positions[dep] < positions[t.name], "#{dep} must precede #{t.name}"
    end
  end

  # ----- MATRIX EXPANSION TESTS -----

  test "expand_matrix with no matrix returns unchanged" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)
    assert Map.has_key?(expanded, "test")
    assert map_size(expanded) == 1
  end

  test "expand_matrix single dimension" do
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"go test","matrix":{"version":["1.0","2.0"]}}]})

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
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"go test","matrix":{"os":["linux","macos"],"version":["1.0","2.0"]}}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    # Should have 4 expanded tasks (2x2)
    assert map_size(expanded) == 4
  end

  test "expand_matrix injects values into env" do
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"go test","matrix":{"version":["1.0"]}}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    task = Map.get(expanded, "test-1.0")
    assert task.env["version"] == "1.0"
  end

  test "expand_matrix updates dependencies" do
    json = ~s({"version":"1","tasks":[
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
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test","matrix":{}}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)
    assert Map.has_key?(expanded, "test")
    assert map_size(expanded) == 1
  end

  # ----- CONDITION PARSING TESTS -----

  test "parses when condition from JSON" do
    json =
      ~s({"version":"1","tasks":[{"name":"deploy","command":"./deploy.sh","when":"branch == 'main'"}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.condition == "branch == 'main'"
  end

  test "when condition is nil when not set" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.condition == nil
  end

  # ----- SECRETS PARSING TESTS -----

  test "parses secrets from JSON" do
    json =
      ~s({"version":"1","tasks":[{"name":"deploy","command":"./deploy.sh","secrets":["GITHUB_TOKEN","NPM_TOKEN"]}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.secrets == ["GITHUB_TOKEN", "NPM_TOKEN"]
  end

  test "secrets is empty list when not set" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.secrets == []
  end

  # ----- SERVICES PARSING TESTS -----

  test "parses services from JSON" do
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"go test","services":[{"image":"postgres:15","name":"db"}]}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert length(task.services) == 1
    assert hd(task.services).image == "postgres:15"
    assert hd(task.services).name == "db"
  end

  test "services is empty list when not set" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.services == []
  end

  test "parses multiple services" do
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"go test","services":[{"image":"postgres:15","name":"db"},{"image":"redis:7","name":"cache"}]}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert length(task.services) == 2
  end

  # ----- ADDITIONAL MATRIX TESTS -----

  test "expand_matrix preserves matrix_values for expanded tasks" do
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"go test","matrix":{"os":["linux"],"ver":["1.0"]}}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)

    # Find the expanded task
    task = expanded |> Map.values() |> hd()
    assert task.matrix_values != nil
    assert task.matrix_values["os"] == "linux"
    assert task.matrix_values["ver"] == "1.0"
  end

  test "expand_matrix with nil matrix returns task unchanged" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    expanded = Sykli.Graph.expand_matrix(graph)
    assert Map.has_key?(expanded, "test")
    task = Map.get(expanded, "test")
    assert task.matrix == nil
  end

  # ----- CONDITION EDGE CASES -----

  test "parses legacy 'condition' field" do
    json =
      ~s({"version":"1","tasks":[{"name":"deploy","command":"./deploy.sh","condition":"branch == 'main'"}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.condition == "branch == 'main'"
  end

  test "when field takes precedence over condition field" do
    json =
      ~s({"version":"1","tasks":[{"name":"deploy","command":"./deploy.sh","when":"tag != ''","condition":"branch == 'main'"}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "deploy")
    assert task.condition == "tag != ''"
  end

  # ----- SERVICE VALIDATION -----

  test "services parses image and name correctly" do
    json =
      ~s({"version":"1","tasks":[{"name":"test","command":"test","services":[{"image":"postgres:15","name":"db"}]}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    service = hd(task.services)
    assert service.image == "postgres:15"
    assert service.name == "db"
  end

  # ----- RETRY TESTS -----

  test "parses retry from JSON" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test","retry":3}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.retry == 3
  end

  test "retry is nil when not set" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.retry == nil
  end

  # ----- TIMEOUT TESTS -----

  test "parses timeout from JSON" do
    json = ~s({"version":"1","tasks":[{"name":"build","command":"make","timeout":600}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "build")
    assert task.timeout == 600
  end

  test "timeout is nil when not set" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.timeout == nil
  end

  # ----- CYCLE DETECTION TESTS -----

  test "detects self-referencing cycle" do
    json = ~s({"version":"1","tasks":[{"name":"a","command":"echo","depends_on":["a"]}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    {:error, {:cycle_detected, path}} = Sykli.Graph.topo_sort(graph)
    assert is_list(path)
    assert "a" in path
  end

  test "detects direct cycle between two tasks" do
    json = ~s({"version":"1","tasks":[
      {"name":"a","command":"echo","depends_on":["b"]},
      {"name":"b","command":"echo","depends_on":["a"]}
    ]})
    {:ok, graph} = Sykli.Graph.parse(json)
    {:error, {:cycle_detected, path}} = Sykli.Graph.topo_sort(graph)
    assert is_list(path)
    assert "a" in path
    assert "b" in path
  end

  test "detects indirect cycle: a -> b -> c -> a" do
    json = ~s({"version":"1","tasks":[
      {"name":"a","command":"echo","depends_on":["b"]},
      {"name":"b","command":"echo","depends_on":["c"]},
      {"name":"c","command":"echo","depends_on":["a"]}
    ]})
    {:ok, graph} = Sykli.Graph.parse(json)
    {:error, {:cycle_detected, path}} = Sykli.Graph.topo_sort(graph)
    assert is_list(path)
    assert length(path) >= 3
  end

  test "no cycle in valid DAG" do
    json = ~s({"version":"1","tasks":[
      {"name":"test","command":"echo"},
      {"name":"build","command":"echo","depends_on":["test"]},
      {"name":"deploy","command":"echo","depends_on":["build"]}
    ]})
    {:ok, graph} = Sykli.Graph.parse(json)
    {:ok, order} = Sykli.Graph.topo_sort(graph)
    assert length(order) == 3
  end

  # ----- TASK_INPUTS TESTS (v2 artifact passing) -----

  test "parses task_inputs from JSON" do
    json = ~s({"version":"1","tasks":[
      {"name":"build","command":"go build -o ./app","outputs":{"binary":"./app"}},
      {"name":"deploy","command":"./deploy.sh","task_inputs":[{"from_task":"build","output":"binary","dest":"./input/app"}],"depends_on":["build"]}
    ]})
    {:ok, graph} = Sykli.Graph.parse(json)

    # Check build outputs are parsed as map
    build = Map.get(graph, "build")
    assert is_map(build.outputs)
    assert build.outputs["binary"] == "./app"

    # Check deploy task_inputs are parsed
    deploy = Map.get(graph, "deploy")
    assert length(deploy.task_inputs) == 1
    [input] = deploy.task_inputs
    assert input.from_task == "build"
    assert input.output == "binary"
    assert input.dest == "./input/app"
  end

  test "task_inputs is empty list when not set" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.task_inputs == []
  end

  test "outputs map format is preserved" do
    json =
      ~s({"version":"1","tasks":[{"name":"build","command":"make","outputs":{"binary":"./app","docs":"./docs"}}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "build")
    assert is_map(task.outputs)
    assert task.outputs["binary"] == "./app"
    assert task.outputs["docs"] == "./docs"
  end

  test "outputs list format is converted to map" do
    json =
      ~s({"version":"1","tasks":[{"name":"build","command":"make","outputs":["./app","./lib"]}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "build")
    assert is_map(task.outputs)
    assert task.outputs["output_0"] == "./app"
    assert task.outputs["output_1"] == "./lib"
  end

  # ----- TASK REQUIREMENTS (NODE LABELS) -----

  test "parses requires from JSON" do
    json =
      ~s({"version":"1","tasks":[{"name":"train","command":"python train.py","requires":["gpu","docker"]}]})

    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "train")
    assert task.requires == ["gpu", "docker"]
  end

  test "requires is empty list when not set" do
    json = ~s({"version":"1","tasks":[{"name":"test","command":"go test"}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "test")
    assert task.requires == []
  end

  test "requires handles single label" do
    json = ~s({"version":"1","tasks":[{"name":"build","command":"make","requires":["docker"]}]})
    {:ok, graph} = Sykli.Graph.parse(json)
    task = Map.get(graph, "build")
    assert task.requires == ["docker"]
  end
end
