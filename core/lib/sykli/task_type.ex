defmodule Sykli.TaskType do
  @moduledoc """
  Shared task_type vocabulary for the semantic pipeline contract.
  """

  @values ~w(build test lint format scan package publish deploy migrate generate verify cleanup)

  @spec all() :: [String.t()]
  def all, do: @values

  @spec valid?(term()) :: boolean()
  def valid?(value), do: value in @values
end
