defmodule Sykli.Pipeline do
  @moduledoc """
  Represents a CI pipeline with tasks and resources.
  """

  defstruct tasks: [],
            resources: %{},
            current_task: nil

  @type t :: %__MODULE__{
          tasks: [Sykli.Task.t()],
          resources: %{String.t() => map()},
          current_task: Sykli.Task.t() | nil
        }

  @doc "Creates a new empty pipeline."
  def new do
    %__MODULE__{}
  end
end
