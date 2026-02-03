defmodule Sykli.Services.ArtifactResolver do
  @moduledoc """
  Service for resolving artifact dependencies between tasks.

  Handles copying artifacts from one task's outputs to another task's inputs
  based on the `task_inputs` configuration.
  """

  alias Sykli.Graph.TaskInput

  @doc """
  Resolve and copy all task inputs for a task.

  Task inputs are artifacts produced by other tasks that need to be
  available for this task's execution.

  Returns `:ok` if all artifacts are resolved, or `{:error, reason}`.
  """
  @spec resolve(Sykli.Graph.Task.t(), map(), map(), module()) ::
          :ok | {:error, term()}
  def resolve(%Sykli.Graph.Task{task_inputs: nil}, _graph, _state, _target), do: :ok
  def resolve(%Sykli.Graph.Task{task_inputs: []}, _graph, _state, _target), do: :ok

  def resolve(%Sykli.Graph.Task{name: task_name, task_inputs: task_inputs}, graph, state, target) do
    results =
      task_inputs
      |> Enum.map(fn %TaskInput{from_task: from_task, output: output_name, dest: dest} ->
        resolve_single_input(task_name, from_task, output_name, dest, graph, state, target)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  @doc """
  Resolve a single artifact input.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec resolve_single_input(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map(),
          map(),
          module()
        ) :: :ok | {:error, term()}
  def resolve_single_input(task_name, from_task, output_name, dest, graph, state, target) do
    workdir = state.workdir

    # Find the source task
    case Map.get(graph, from_task) do
      nil ->
        log_error(task_name, "source task '#{from_task}' not found")
        {:error, {:source_task_not_found, from_task}}

      source_task ->
        # Find the output path by name (normalize to map format)
        outputs = normalize_outputs_to_map(source_task.outputs)

        case Map.get(outputs, output_name) do
          nil ->
            log_error(task_name, "output '#{output_name}' not found in task '#{from_task}'")
            {:error, {:output_not_found, from_task, output_name}}

          source_path ->
            # Copy artifact via target
            case target.copy_artifact(source_path, dest, workdir, state) do
              :ok ->
                log_copy(source_path, dest)
                :ok

              {:error, reason} ->
                log_error(task_name, "failed to copy #{source_path}: #{inspect(reason)}")
                {:error, {:copy_failed, source_path, reason}}
            end
        end
    end
  end

  # Convert outputs to map format (for artifact lookup by name)
  defp normalize_outputs_to_map(nil), do: %{}
  defp normalize_outputs_to_map(outputs) when is_map(outputs), do: outputs

  defp normalize_outputs_to_map(outputs) when is_list(outputs) do
    outputs
    |> Enum.with_index()
    |> Map.new(fn {path, idx} -> {"output_#{idx}", path} end)
  end

  defp log_error(task_name, message) do
    IO.puts("#{IO.ANSI.red()}✗ #{task_name}: #{message}#{IO.ANSI.reset()}")
  end

  defp log_copy(source, dest) do
    IO.puts("  #{IO.ANSI.faint()}← #{source} → #{dest}#{IO.ANSI.reset()}")
  end
end
