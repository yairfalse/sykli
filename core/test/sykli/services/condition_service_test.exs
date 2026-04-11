defmodule Sykli.Services.ConditionServiceTest do
  use ExUnit.Case, async: false

  alias Sykli.Services.ConditionService

  # Helper to set env vars with cleanup
  defp with_env(vars, fun) do
    saved =
      Enum.map(vars, fn {key, _val} -> {key, System.get_env(key)} end)

    Enum.each(vars, fn {key, val} ->
      if val, do: System.put_env(key, val), else: System.delete_env(key)
    end)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)
    end
  end

  describe "should_run?/1" do
    test "returns true when condition is nil" do
      task = %Sykli.Graph.Task{condition: nil}
      assert ConditionService.should_run?(task) == true
    end

    test "returns true when condition is empty string" do
      task = %Sykli.Graph.Task{condition: ""}
      assert ConditionService.should_run?(task) == true
    end
  end

  describe "check/1" do
    test "returns true for nil condition" do
      assert ConditionService.check(nil) == true
    end

    test "returns true for empty string condition" do
      assert ConditionService.check("") == true
    end
  end

  describe "build_context/0" do
    test "includes ci flag from CI env var" do
      with_env([{"CI", "true"}], fn ->
        context = ConditionService.build_context()
        assert context.ci == true
      end)
    end

    test "ci flag is false when CI env var not set" do
      with_env([{"CI", nil}], fn ->
        context = ConditionService.build_context()
        assert context.ci == false
      end)
    end

    test "reads GitHub event name" do
      with_env([{"GITHUB_EVENT_NAME", "push"}], fn ->
        context = ConditionService.build_context()
        assert context.event == "push"
      end)
    end

    test "reads GitHub PR number" do
      with_env([{"GITHUB_PR_NUMBER", "42"}], fn ->
        context = ConditionService.build_context()
        assert context.pr_number == "42"
      end)
    end
  end

  describe "get_branch/0" do
    test "returns branch from GitHub Actions when ref type is branch" do
      with_env(
        [
          {"GITHUB_REF_NAME", "main"},
          {"GITHUB_REF_TYPE", "branch"},
          {"CI_COMMIT_BRANCH", nil}
        ],
        fn ->
          assert ConditionService.get_branch() == "main"
        end
      )
    end

    test "returns nil from GitHub Actions when ref type is tag" do
      with_env(
        [
          {"GITHUB_REF_NAME", "v1.0.0"},
          {"GITHUB_REF_TYPE", "tag"},
          {"CI_COMMIT_BRANCH", nil}
        ],
        fn ->
          assert ConditionService.get_branch() == nil
        end
      )
    end

    test "returns branch from GitLab CI" do
      with_env(
        [
          {"GITHUB_REF_NAME", nil},
          {"GITHUB_REF_TYPE", nil},
          {"CI_COMMIT_BRANCH", "develop"}
        ],
        fn ->
          assert ConditionService.get_branch() == "develop"
        end
      )
    end
  end

  describe "get_tag/0" do
    test "returns tag from GitHub Actions when ref type is tag" do
      with_env(
        [
          {"GITHUB_REF_TYPE", "tag"},
          {"GITHUB_REF_NAME", "v2.0.0"},
          {"CI_COMMIT_TAG", nil}
        ],
        fn ->
          assert ConditionService.get_tag() == "v2.0.0"
        end
      )
    end

    test "returns nil from GitHub Actions when ref type is branch" do
      with_env(
        [
          {"GITHUB_REF_TYPE", "branch"},
          {"GITHUB_REF_NAME", "main"},
          {"CI_COMMIT_TAG", nil}
        ],
        fn ->
          assert ConditionService.get_tag() == nil
        end
      )
    end

    test "returns tag from GitLab CI" do
      with_env(
        [
          {"GITHUB_REF_TYPE", nil},
          {"GITHUB_REF_NAME", nil},
          {"CI_COMMIT_TAG", "v3.0.0"}
        ],
        fn ->
          assert ConditionService.get_tag() == "v3.0.0"
        end
      )
    end

    test "returns nil when no tag env vars set" do
      with_env(
        [
          {"GITHUB_REF_TYPE", nil},
          {"GITHUB_REF_NAME", nil},
          {"CI_COMMIT_TAG", nil}
        ],
        fn ->
          assert ConditionService.get_tag() == nil
        end
      )
    end
  end
end
