defmodule Sykli.Services.ConditionService do
  @moduledoc """
  Service for evaluating task conditions.

  Handles the `when:` condition logic for tasks, determining whether
  a task should run based on branch, tag, event, and other context.
  """

  @doc """
  Check if a task should run based on its condition.

  Returns `true` if the task should run, `false` if it should be skipped.
  Tasks without conditions always run.
  """
  @spec should_run?(Sykli.Graph.Task.t()) :: boolean()
  def should_run?(%Sykli.Graph.Task{condition: nil}), do: true
  def should_run?(%Sykli.Graph.Task{condition: ""}), do: true

  def should_run?(%Sykli.Graph.Task{condition: condition}) do
    context = build_context()
    evaluate_condition(condition, context)
  end

  @doc """
  Check a condition string against the current context.

  Returns `true` if condition is met, `false` otherwise.
  """
  @spec check(String.t() | nil) :: boolean()
  def check(nil), do: true
  def check(""), do: true

  def check(condition) when is_binary(condition) do
    context = build_context()
    evaluate_condition(condition, context)
  end

  @doc """
  Build execution context from environment variables.

  CI systems set these environment variables that can be used in conditions.
  """
  @spec build_context() :: map()
  def build_context do
    %{
      # GitHub Actions
      branch: get_branch(),
      tag: get_tag(),
      event: System.get_env("GITHUB_EVENT_NAME"),
      pr_number: System.get_env("GITHUB_PR_NUMBER"),
      # Generic CI
      ci: System.get_env("CI") == "true"
    }
  end

  @doc """
  Build context as a string-keyed map (for legacy compatibility).
  """
  @spec build_context_map() :: map()
  def build_context_map do
    %{
      "branch" => get_branch(),
      "tag" => get_tag(),
      "event" => System.get_env("GITHUB_EVENT_NAME"),
      "pr_number" => System.get_env("GITHUB_PR_NUMBER"),
      "ci" => System.get_env("CI") == "true"
    }
  end

  @doc """
  Get the current branch name.
  """
  @spec get_branch() :: String.t() | nil
  def get_branch do
    cond do
      # GitHub Actions
      ref = System.get_env("GITHUB_REF_NAME") ->
        if System.get_env("GITHUB_REF_TYPE") == "branch", do: ref, else: nil

      # GitLab CI
      branch = System.get_env("CI_COMMIT_BRANCH") ->
        branch

      # Generic / local - try git (with timeout)
      true ->
        case Sykli.Git.branch(timeout: 5_000) do
          {:ok, branch} -> branch
          _ -> nil
        end
    end
  end

  @doc """
  Get the current tag name (if any).
  """
  @spec get_tag() :: String.t() | nil
  def get_tag do
    cond do
      System.get_env("GITHUB_REF_TYPE") == "tag" ->
        System.get_env("GITHUB_REF_NAME")

      tag = System.get_env("CI_COMMIT_TAG") ->
        tag

      true ->
        nil
    end
  end

  # Evaluate a condition expression against context using safe evaluator
  defp evaluate_condition(condition, context) do
    case Sykli.ConditionEvaluator.evaluate(condition, context) do
      {:ok, result} ->
        !!result

      {:error, reason} ->
        IO.puts(
          "#{IO.ANSI.yellow()}⚠ Invalid condition: #{condition} (#{reason})#{IO.ANSI.reset()}"
        )

        # On error, skip the task (safer than running)
        false
    end
  end
end
