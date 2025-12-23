defmodule Sykli.TaskGroup do
  @moduledoc """
  Represents a group of tasks that run in parallel.

  Created by `parallel/2` and can be used as a dependency with `after_group/1`.

  ## Example

      pipeline do
        checks = parallel("checks", [
          task("lint") |> run("mix credo"),
          task("test") |> run("mix test"),
          task("format") |> run("mix format --check-formatted")
        ])

        task "build" do
          run "mix compile"
          after_group checks
        end
      end
  """

  defstruct name: nil,
            tasks: []

  @type t :: %__MODULE__{
          name: String.t(),
          tasks: [Sykli.Task.t()]
        }

  @doc "Creates a new task group."
  def new(name, tasks) when is_binary(name) and is_list(tasks) do
    %__MODULE__{name: name, tasks: tasks}
  end

  @doc "Returns the names of all tasks in this group."
  def task_names(%__MODULE__{tasks: tasks}) do
    Enum.map(tasks, & &1.name)
  end

  @doc "Adds dependencies to all tasks in the group."
  def after_deps(%__MODULE__{} = group, deps) when is_list(deps) do
    updated_tasks =
      Enum.map(group.tasks, fn task ->
        %{task | depends_on: task.depends_on ++ deps}
      end)

    %{group | tasks: updated_tasks}
  end
end
