defmodule Sykli.CLI.JsonResponseTest do
  use ExUnit.Case, async: true

  alias Sykli.CLI.JsonResponse

  describe "ok/1" do
    test "wraps data in envelope" do
      result = JsonResponse.ok(%{tasks: ["test", "build"]}) |> Jason.decode!()

      assert result["ok"] == true
      assert result["version"] == "1"
      assert result["data"] == %{"tasks" => ["test", "build"]}
      assert result["error"] == nil
    end

    test "handles nil data" do
      result = JsonResponse.ok(nil) |> Jason.decode!()

      assert result["ok"] == true
      assert result["data"] == nil
    end
  end

  describe "error/1 with Sykli.Error" do
    test "wraps error struct in envelope" do
      err = Sykli.Error.no_sdk_file("/tmp/test")
      result = JsonResponse.error(err) |> Jason.decode!()

      assert result["ok"] == false
      assert result["version"] == "1"
      assert result["data"] == nil
      assert result["error"]["code"] == "sdk_not_found"
      assert is_binary(result["error"]["message"])
      assert is_list(result["error"]["hints"])
      assert length(result["error"]["hints"]) > 0
    end

    test "wraps task_failed error" do
      err = Sykli.Error.task_failed("build", "go build", 1, "error: undefined")
      result = JsonResponse.error(err) |> Jason.decode!()

      assert result["error"]["code"] == "task_failed"
      assert result["error"]["message"] =~ "build"
    end

    test "wraps cycle_detected error" do
      err = Sykli.Error.cycle_detected(["a", "b", "a"])
      result = JsonResponse.error(err) |> Jason.decode!()

      assert result["error"]["code"] == "dependency_cycle"
    end
  end

  describe "error/1 with string" do
    test "wraps plain string error" do
      result = JsonResponse.error("something went wrong") |> Jason.decode!()

      assert result["ok"] == false
      assert result["error"]["code"] == "unknown"
      assert result["error"]["message"] == "something went wrong"
      assert result["error"]["hints"] == []
    end
  end

  describe "envelope shape consistency" do
    test "ok and error have the same top-level keys" do
      ok_keys = JsonResponse.ok(%{}) |> Jason.decode!() |> Map.keys() |> Enum.sort()
      err_keys = JsonResponse.error("x") |> Jason.decode!() |> Map.keys() |> Enum.sort()

      assert ok_keys == err_keys
      assert ok_keys == ["data", "error", "ok", "version"]
    end
  end
end
