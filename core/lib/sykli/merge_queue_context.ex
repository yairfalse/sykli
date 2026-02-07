defmodule Sykli.MergeQueueContext do
  @moduledoc """
  Context for merge queue runs (GitHub merge_group, GitLab merge train).
  """

  defstruct [:provider, :head_sha, :base_sha, :target_branch, :pr_numbers, :queue_depth]

  @type provider :: :github | :gitlab | :generic
  @type t :: %__MODULE__{
    provider: provider(),
    head_sha: String.t() | nil,
    base_sha: String.t() | nil,
    target_branch: String.t() | nil,
    pr_numbers: [integer()],
    queue_depth: non_neg_integer() | nil
  }

  def to_map(%__MODULE__{} = ctx) do
    %{
      "provider" => Atom.to_string(ctx.provider),
      "head_sha" => ctx.head_sha,
      "base_sha" => ctx.base_sha,
      "target_branch" => ctx.target_branch,
      "pr_numbers" => ctx.pr_numbers,
      "queue_depth" => ctx.queue_depth
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end
