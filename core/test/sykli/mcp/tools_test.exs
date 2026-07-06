defmodule Sykli.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Sykli.Error
  alias Sykli.MCP.Tools

  describe "list/0" do
    test "returns 7 tool definitions" do
      tools = Tools.list()
      assert length(tools) == 7
    end

    test "each tool has name, description, and inputSchema" do
      Enum.each(Tools.list(), fn tool ->
        assert is_binary(tool["name"]), "Tool missing name"
        assert is_binary(tool["description"]), "Tool #{tool["name"]} missing description"
        assert is_map(tool["inputSchema"]), "Tool #{tool["name"]} missing inputSchema"
        assert tool["inputSchema"]["type"] == "object"
      end)
    end

    test "all tools have path parameter" do
      Enum.each(Tools.list(), fn tool ->
        props = tool["inputSchema"]["properties"] || %{}
        assert Map.has_key?(props, "path"), "Tool #{tool["name"]} missing path param"
      end)
    end
  end

  describe "call/2" do
    test "unknown tool returns a coded error" do
      assert {:error, %Error{code: "mcp.unknown_tool"} = err} = Tools.call("bogus", %{})
      assert err.hints != []
    end

    test "explain_pipeline with nonexistent path returns a coded error" do
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      assert {:error, %Error{} = err} = Tools.call("explain_pipeline", %{"path" => path})
      assert is_binary(err.code)
      assert is_binary(err.message)
    end

    test "get_history with empty dir returns empty runs" do
      path = System.tmp_dir!() |> Path.join("sykli-mcp-test-#{:rand.uniform(999_999)}")
      File.mkdir_p!(path)

      on_exit(fn -> File.rm_rf!(path) end)

      assert {:ok, result} = Tools.call("get_history", %{"path" => path})
      assert result.runs == []
      assert result.patterns == %{}
    end

    test "get_failure with no data returns mcp.no_occurrence" do
      path = System.tmp_dir!() |> Path.join("sykli-mcp-test-#{:rand.uniform(999_999)}")
      File.mkdir_p!(path)

      on_exit(fn -> File.rm_rf!(path) end)

      assert {:error, %Error{code: "mcp.no_occurrence"}} =
               Tools.call("get_failure", %{"path" => path})
    end

    test "missing required tasks argument returns mcp.missing_argument" do
      assert {:error, %Error{code: "mcp.missing_argument"}} =
               Tools.call("retry_task", %{"tasks" => []})
    end

    test "tool crash is caught and returns a coded error" do
      # suggest_tests with a nonexistent path should return an error, not crash
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      result = Tools.call("suggest_tests", %{"path" => path})
      assert {:error, %Error{}} = result
    end

    test "retry_task with nonexistent path returns a coded error" do
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      result = Tools.call("retry_task", %{"path" => path, "tasks" => ["some_task"]})
      assert {:error, %Error{} = err} = result
      assert is_binary(err.message)
    end

    test "run_fix with nonexistent path returns a coded error" do
      path = "/tmp/sykli-mcp-test-#{:rand.uniform(999_999)}"
      result = Tools.call("run_fix", %{"path" => path})
      assert {:error, %Error{} = err} = result
      assert is_binary(err.message)
    end

    test "run_pipeline exposes agent-readable failure facts" do
      path = System.tmp_dir!() |> Path.join("sykli-mcp-test-#{:rand.uniform(999_999)}")
      File.mkdir_p!(path)
      write_pipeline(path)

      on_exit(fn -> File.rm_rf!(path) end)

      assert {:ok, result} = Tools.call("run_pipeline", %{"path" => path})
      assert is_binary(Jason.encode!(result))
      assert result.status == "failed"

      [task] = result.tasks
      assert task.name == "contract-check"
      assert task.error.code == "success_criteria_failed"
      assert task.error.type == "execution"
      assert task.error.step == "run"
      assert task.failure_semantics["class"] == "criteria_failure"
      assert task.agent_hints["inspect_contract"] == true
      assert task.agent_hints["inspect_target"] == false
      assert task.contract_slice["task_type"] == "test"
      assert task.contract_slice["semantic"]["intent"] == "check declared outcome"
      assert task.contract_slice["success_criteria"] == [%{"type" => "exit_code", "equals" => 1}]

      assert [
               %{
                 "type" => "exit_code",
                 "status" => "failed"
               }
             ] = task.success_criteria_results

      # No mandate declared -> no mandate_outcome key on the MCP surface.
      refute Map.has_key?(task, :mandate_outcome)
    end

    test "run_pipeline exposes mandate_outcome when the result carries one" do
      path = System.tmp_dir!() |> Path.join("sykli-mcp-test-#{:rand.uniform(999_999)}")
      File.mkdir_p!(path)
      write_mandate_pipeline(path)

      on_exit(fn -> File.rm_rf!(path) end)

      assert {:ok, result} = Tools.call("run_pipeline", %{"path" => path})
      assert is_binary(Jason.encode!(result))
      assert result.status == "failed"

      [task] = result.tasks
      assert task.name == "scoped"
      # Scope enforcement requires a git work tree; a bare tmp dir yields an
      # explicit "unsupported" outcome — proving the field crosses the MCP surface.
      assert task.mandate_outcome["status"] == "unsupported"
      assert task.mandate_outcome["reason"] == "mandate_requires_git"
    end
  end

  describe "list/0 tool names" do
    test "includes retry_task and run_fix" do
      names = Tools.list() |> Enum.map(& &1["name"])
      assert "retry_task" in names
      assert "run_fix" in names
    end

    test "all 7 expected tool names are present" do
      names = Tools.list() |> Enum.map(& &1["name"]) |> MapSet.new()

      expected =
        MapSet.new([
          "run_pipeline",
          "explain_pipeline",
          "get_failure",
          "suggest_tests",
          "get_history",
          "retry_task",
          "run_fix"
        ])

      assert MapSet.equal?(names, expected)
    end
  end

  defp write_pipeline(path) do
    json =
      Jason.encode!(%{
        "version" => "3",
        "tasks" => [
          %{
            "name" => "contract-check",
            "command" => "true",
            "task_type" => "test",
            "semantic" => %{"intent" => "check declared outcome"},
            "success_criteria" => [%{"type" => "exit_code", "equals" => 1}]
          }
        ]
      })

    File.write!(Path.join(path, "sykli.exs"), "IO.puts(#{inspect(json)})")
  end

  defp write_mandate_pipeline(path) do
    json =
      Jason.encode!(%{
        "version" => "5",
        "tasks" => [
          %{
            "name" => "scoped",
            "command" => "true",
            "mandate" => %{"scope" => ["allowed/**"]}
          }
        ]
      })

    File.write!(Path.join(path, "sykli.exs"), "IO.puts(#{inspect(json)})")
  end
end
