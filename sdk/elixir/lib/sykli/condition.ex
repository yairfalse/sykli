defmodule Sykli.Condition do
  @moduledoc """
  Type-safe conditions for when a task should run.

  Use the builder functions to create conditions:

  ## Examples

      # Run on main branch or when tagged
      Condition.branch("main") |> Condition.or_cond(Condition.tag("v*"))

      # Run when not on WIP branch
      Condition.not_cond(Condition.branch("wip/*"))

      # Run in CI on push events
      Condition.in_ci() |> Condition.and_cond(Condition.event("push"))
  """

  defstruct expr: ""

  @type t :: %__MODULE__{expr: String.t()}

  @doc """
  Creates a condition that matches a branch name or pattern.
  Supports glob patterns like "feature/*".

  ## Examples

      Condition.branch("main")        # branch == 'main'
      Condition.branch("release/*")   # branch matches 'release/*'

  Raises ArgumentError if pattern is empty.
  """
  @spec branch(String.t()) :: t()
  def branch(pattern) when is_binary(pattern) do
    if pattern == "" do
      raise ArgumentError, "Condition.branch() requires a non-empty pattern"
    end

    if String.contains?(pattern, "*") do
      %__MODULE__{expr: "branch matches '#{pattern}'"}
    else
      %__MODULE__{expr: "branch == '#{pattern}'"}
    end
  end

  @doc """
  Creates a condition that matches a tag name or pattern.
  Supports glob patterns like "v*".

  ## Examples

      Condition.tag("v*")        # tag matches 'v*'
      Condition.tag("v1.0.0")    # tag == 'v1.0.0'
  """
  @spec tag(String.t()) :: t()
  def tag(pattern) when is_binary(pattern) do
    cond do
      pattern == "" ->
        %__MODULE__{expr: "tag != ''"}
      String.contains?(pattern, "*") ->
        %__MODULE__{expr: "tag matches '#{pattern}'"}
      true ->
        %__MODULE__{expr: "tag == '#{pattern}'"}
    end
  end

  @doc """
  Creates a condition that matches when any tag is present.

  ## Examples

      Condition.has_tag()  # tag != ''
  """
  @spec has_tag() :: t()
  def has_tag do
    %__MODULE__{expr: "tag != ''"}
  end

  @doc """
  Creates a condition that matches a CI event type.

  ## Examples

      Condition.event("push")           # event == 'push'
      Condition.event("pull_request")   # event == 'pull_request'
  """
  @spec event(String.t()) :: t()
  def event(event_type) when is_binary(event_type) do
    %__MODULE__{expr: "event == '#{event_type}'"}
  end

  @doc """
  Creates a condition that matches when running in CI.

  ## Examples

      Condition.in_ci()  # ci == true
  """
  @spec in_ci() :: t()
  def in_ci do
    %__MODULE__{expr: "ci == true"}
  end

  @doc """
  Negates a condition.

  ## Examples

      Condition.not_cond(Condition.branch("wip/*"))  # !(branch matches 'wip/*')
  """
  @spec not_cond(t()) :: t()
  def not_cond(%__MODULE__{expr: expr}) do
    %__MODULE__{expr: "!(#{expr})"}
  end

  @doc """
  Combines conditions with OR logic.

  ## Examples

      Condition.branch("main") |> Condition.or_cond(Condition.tag("v*"))
      # (branch == 'main') || (tag matches 'v*')
  """
  @spec or_cond(t(), t()) :: t()
  def or_cond(%__MODULE__{expr: left}, %__MODULE__{expr: right}) do
    %__MODULE__{expr: "(#{left}) || (#{right})"}
  end

  @doc """
  Combines conditions with AND logic.

  ## Examples

      Condition.branch("main") |> Condition.and_cond(Condition.event("push"))
      # (branch == 'main') && (event == 'push')
  """
  @spec and_cond(t(), t()) :: t()
  def and_cond(%__MODULE__{expr: left}, %__MODULE__{expr: right}) do
    %__MODULE__{expr: "(#{left}) && (#{right})"}
  end

  @doc """
  Returns the condition expression as a string.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{expr: expr}), do: expr
end
