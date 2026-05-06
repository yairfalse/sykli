defmodule Sykli.Validate do
  @moduledoc """
  Validates sykli pipeline configuration.

  Checks for:
  - Dependency cycles
  - Missing dependencies
  - Empty/invalid task names
  - Duplicate task names
  - Self-dependencies
  """

  alias Sykli.{Detector, Graph}

  defmodule Result do
    @moduledoc "Validation result"
    defstruct valid: true, tasks: [], errors: [], warnings: []

    @type t :: %__MODULE__{
            valid: boolean(),
            tasks: [String.t()],
            errors: [map()],
            warnings: [tuple()]
          }
  end

  # ----- PUBLIC API -----

  @doc """
  Validate a sykli project at the given path.
  """
  @spec validate(String.t()) :: {:ok, Result.t()} | {:error, term()}
  def validate(path) do
    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file) do
      result = validate_json(json)
      {:ok, result}
    end
  end

  @doc """
  Validate a JSON task graph directly.
  """
  @spec validate_json(String.t()) :: Result.t()
  def validate_json(json) do
    case Jason.decode(json) do
      {:ok, data} ->
        validate_data(data)

      {:error, _reason} ->
        %Result{
          valid: false,
          errors: [%{type: :invalid_json, message: "Failed to parse JSON"}]
        }
    end
  end

  @doc """
  Format validation errors for CLI output.
  """
  @spec format_errors(Result.t()) :: String.t()
  def format_errors(%Result{errors: errors}) do
    errors
    |> Enum.map(&format_error/1)
    |> Enum.join("\n")
  end

  @doc """
  Convert result to a plain map (for JSON serialization).
  """
  @spec to_map(Result.t()) :: map()
  def to_map(%Result{} = result) do
    %{
      valid: result.valid,
      tasks: result.tasks,
      errors: result.errors,
      warnings: Enum.map(result.warnings, fn {type, msg} -> %{type: type, message: msg} end)
    }
  end

  # ----- PRIVATE -----

  defp validate_data(data) do
    tasks = data["tasks"] || []
    version = Map.get(data, "version", "1")

    task_names =
      tasks
      |> Enum.map(& &1["name"])
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

    errors =
      []
      |> check_empty_names(tasks)
      |> check_duplicates(task_names)
      |> check_self_deps(tasks)
      |> check_missing_deps(tasks, task_names)
      |> check_missing_commands(tasks)
      |> check_task_types(tasks, version)
      |> check_cycles(tasks)

    warnings =
      if tasks == [] do
        [{:no_tasks, "Pipeline has no tasks"}]
      else
        []
      end

    %Result{
      valid: errors == [],
      tasks: task_names,
      errors: errors,
      warnings: warnings
    }
  end

  defp check_empty_names(errors, tasks) do
    empty_tasks =
      tasks
      |> Enum.filter(fn t ->
        name = t["name"]
        is_nil(name) or not is_binary(name) or String.trim(name) == ""
      end)

    if empty_tasks != [] do
      [%{type: :empty_task_name, message: "Task has empty or missing name"} | errors]
    else
      errors
    end
  end

  defp check_duplicates(errors, task_names) do
    duplicates =
      task_names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    Enum.reduce(duplicates, errors, fn name, acc ->
      [%{type: :duplicate_task, task: name, message: "Duplicate task name: #{name}"} | acc]
    end)
  end

  defp valid_name?(name), do: is_binary(name) and String.trim(name) != ""

  defp check_self_deps(errors, tasks) do
    self_deps =
      tasks
      |> Enum.filter(fn t ->
        name = t["name"]
        deps = t["depends_on"] || []
        valid_name?(name) and name in deps
      end)
      |> Enum.map(& &1["name"])

    Enum.reduce(self_deps, errors, fn name, acc ->
      [%{type: :self_dependency, task: name, message: "Task '#{name}' depends on itself"} | acc]
    end)
  end

  defp check_missing_deps(errors, tasks, task_names) do
    task_name_set = MapSet.new(task_names)

    missing =
      tasks
      |> Enum.filter(fn t -> valid_name?(t["name"]) end)
      |> Enum.flat_map(fn t ->
        name = t["name"]
        deps = t["depends_on"] || []

        deps
        |> Enum.reject(&MapSet.member?(task_name_set, &1))
        |> Enum.map(fn dep -> {name, dep} end)
      end)

    Enum.reduce(missing, errors, fn {task, dep}, acc ->
      [
        %{
          type: :missing_dependency,
          task: task,
          dependency: dep,
          message: "Task '#{task}' depends on unknown task '#{dep}'"
        }
        | acc
      ]
    end)
  end

  defp check_cycles(errors, tasks) do
    # Short-circuit cycle detection if there are already critical dependency errors.
    has_critical_dependency_errors? =
      Enum.any?(errors, fn
        %{type: type} when type in [:missing_dependency, :self_dependency] -> true
        _ -> false
      end)

    if has_critical_dependency_errors? do
      errors
    else
      # Build graph for cycle detection (only valid tasks)
      graph =
        tasks
        |> Enum.filter(fn t -> valid_name?(t["name"]) end)
        |> Enum.map(fn t ->
          {t["name"],
           %{
             name: t["name"],
             depends_on: t["depends_on"] || []
           }}
        end)
        |> Map.new()

      case Graph.topo_sort(graph) do
        {:ok, _} ->
          errors

        {:error, {:cycle_detected, path}} ->
          cycle_str = Enum.join(path, " -> ")

          [
            %{type: :cycle, path: path, message: "Dependency cycle detected: #{cycle_str}"}
            | errors
          ]

        {:error, _} ->
          # Generic cycle error
          [%{type: :cycle, message: "Dependency cycle detected"} | errors]
      end
    end
  end

  defp check_missing_commands(errors, tasks) do
    tasks
    |> Enum.filter(fn t -> valid_name?(t["name"]) end)
    |> Enum.reject(fn t ->
      # Gate tasks don't need a command
      t["gate"] != nil or t["kind"] == "review"
    end)
    |> Enum.filter(fn t ->
      cmd = t["command"]
      is_nil(cmd) or (is_binary(cmd) and String.trim(cmd) == "")
    end)
    |> Enum.reduce(errors, fn t, acc ->
      name = t["name"]

      [
        %{
          type: :missing_command,
          task: name,
          message: "Task '#{name}' has no command"
        }
        | acc
      ]
    end)
  end

  defp check_task_types(errors, tasks, version) do
    tasks
    |> Enum.filter(fn t -> valid_name?(t["name"]) and Map.has_key?(t, "task_type") end)
    |> Enum.reduce(errors, fn t, acc ->
      name = t["name"]
      task_type = t["task_type"]

      cond do
        t["kind"] == "review" ->
          [
            %{
              type: :task_type_on_review,
              task: name,
              message: "Review node '#{name}' cannot declare task_type"
            }
            | acc
          ]

        version != "3" ->
          [
            %{
              type: :task_type_requires_version_3,
              task: name,
              message: "Task '#{name}' declares task_type but pipeline version is not 3"
            }
            | acc
          ]

        not Sykli.TaskType.valid?(task_type) ->
          [
            %{
              type: :unknown_task_type,
              task: name,
              message: "Task '#{name}' declares unknown task_type '#{task_type}'"
            }
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp format_error(%{type: :missing_command, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :task_type_on_review, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :task_type_requires_version_3, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :unknown_task_type, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :cycle, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :missing_dependency, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :duplicate_task, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :self_dependency, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :empty_task_name, message: msg}), do: "Error: #{msg}"
  defp format_error(%{type: :invalid_json, message: msg}), do: "Error: #{msg}"
  defp format_error(%{message: msg}), do: "Error: #{msg}"
  defp format_error(error), do: "Error: #{inspect(error)}"
end
