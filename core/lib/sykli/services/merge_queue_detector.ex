defmodule Sykli.Services.MergeQueueDetector do
  @moduledoc """
  Detects merge queue context from CI environment variables.
  """

  alias Sykli.MergeQueueContext

  @doc """
  Detect if running in a merge queue.
  Returns {:ok, context} or :not_in_merge_queue.
  """
  @spec detect() :: {:ok, MergeQueueContext.t()} | :not_in_merge_queue
  def detect do
    cond do
      github_merge_group?() -> {:ok, detect_github()}
      gitlab_merge_train?() -> {:ok, detect_gitlab()}
      true -> :not_in_merge_queue
    end
  end

  @doc "Returns true if currently in a merge queue."
  @spec in_merge_queue?() :: boolean()
  def in_merge_queue? do
    github_merge_group?() or gitlab_merge_train?()
  end

  defp github_merge_group? do
    System.get_env("GITHUB_EVENT_NAME") == "merge_group"
  end

  defp gitlab_merge_train? do
    System.get_env("CI_MERGE_REQUEST_EVENT_TYPE") == "merge_train"
  end

  defp detect_github do
    %MergeQueueContext{
      provider: :github,
      head_sha: System.get_env("GITHUB_SHA"),
      base_sha: System.get_env("MERGE_GROUP_BASE_SHA"),
      target_branch: System.get_env("GITHUB_BASE_REF") || System.get_env("MERGE_GROUP_BASE_REF"),
      pr_numbers: parse_pr_numbers(System.get_env("MERGE_GROUP_HEAD_REF")),
      queue_depth: nil
    }
  end

  defp detect_gitlab do
    %MergeQueueContext{
      provider: :gitlab,
      head_sha: System.get_env("CI_COMMIT_SHA"),
      base_sha: System.get_env("CI_MERGE_REQUEST_TARGET_BRANCH_SHA"),
      target_branch: System.get_env("CI_MERGE_REQUEST_TARGET_BRANCH_NAME"),
      pr_numbers: parse_gitlab_mr_iid(),
      queue_depth: nil
    }
  end

  # Parse PR numbers from GitHub merge group ref (e.g., "gh-readonly-queue/main/pr-123-...")
  defp parse_pr_numbers(nil), do: []
  defp parse_pr_numbers(ref) do
    Regex.scan(~r/pr-(\d+)/, ref)
    |> Enum.map(fn [_, num] -> String.to_integer(num) end)
  end

  defp parse_gitlab_mr_iid do
    case System.get_env("CI_MERGE_REQUEST_IID") do
      nil -> []
      iid -> [String.to_integer(iid)]
    end
  end
end
