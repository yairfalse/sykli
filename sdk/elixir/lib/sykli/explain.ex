defmodule Sykli.Explain do
  @moduledoc """
  Prints a human-readable execution plan for a pipeline.

  This is useful for debugging pipelines and understanding what will run.
  """

  @doc """
  Context for evaluating conditions during explain/dry-run.
  """
  defstruct branch: "", tag: "", event: "", ci: false

  @type t :: %__MODULE__{
          branch: String.t(),
          tag: String.t(),
          event: String.t(),
          ci: boolean()
        }

  @doc """
  Prints the execution plan to stdout.

  ## Examples

      pipeline = define_pipeline()
      Sykli.Explain.explain(pipeline)
      Sykli.Explain.explain(pipeline, %Sykli.Explain{branch: "feature/foo"})
  """
  @spec explain(Sykli.Pipeline.t(), t() | nil) :: :ok
  def explain(pipeline, ctx \\ nil) do
    explain_to(pipeline, :stdio, ctx)
  end

  @doc """
  Writes the execution plan to the given IO device or file.
  """
  @spec explain_to(Sykli.Pipeline.t(), IO.device(), t() | nil) :: :ok
  def explain_to(pipeline, device, ctx) do
    ctx = ctx || %__MODULE__{}
    sorted = topological_sort(pipeline.tasks)

    IO.puts(device, "Pipeline Execution Plan")
    IO.puts(device, "=======================")

    sorted
    |> Enum.with_index(1)
    |> Enum.each(fn {task, index} ->
      print_task(device, task, index, ctx)
    end)

    :ok
  end

  defp print_task(device, task, index, ctx) do
    # Build header
    header = "#{index}. #{task.name}"

    # Add dependencies
    header = if task.depends_on != [] do
      header <> " (after: #{Enum.join(task.depends_on, ", ")})"
    else
      header
    end

    # Add target override
    header = if task.target_name do
      header <> " [target: #{task.target_name}]"
    else
      header
    end

    # Check condition
    condition = get_effective_condition(task)
    header = case would_skip(condition, ctx) do
      nil -> header
      reason -> header <> " [SKIPPED: #{reason}]"
    end

    IO.puts(device, header)
    IO.puts(device, "   Command: #{task.command}")

    if condition do
      IO.puts(device, "   Condition: #{condition}")
    end

    # Print secrets
    cond do
      task.secret_refs != [] ->
        secrets = Enum.map(task.secret_refs, fn ref ->
          source = case ref.source do
            :env -> "env"
            :file -> "file"
            :vault -> "vault"
          end
          "#{ref.name} (#{source}:#{ref.key})"
        end)
        IO.puts(device, "   Secrets: #{Enum.join(secrets, ", ")}")

      task.secrets != [] ->
        IO.puts(device, "   Secrets: #{Enum.join(task.secrets, ", ")}")

      true ->
        :ok
    end

    IO.puts(device, "")
  end

  defp get_effective_condition(task) do
    case task.when_cond do
      %Sykli.Condition{expr: expr} when expr != "" -> expr
      _ -> task.condition
    end
  end

  defp would_skip(nil, _ctx), do: nil
  defp would_skip(condition, ctx) do
    condition = String.trim(condition)

    cond do
      # branch == 'value'
      String.starts_with?(condition, "branch == '") ->
        expected = condition
          |> String.trim_leading("branch == '")
          |> String.trim_trailing("'")
        if ctx.branch != expected do
          "branch is '#{ctx.branch}', not '#{expected}'"
        else
          nil
        end

      # branch != 'value'
      String.starts_with?(condition, "branch != '") ->
        excluded = condition
          |> String.trim_leading("branch != '")
          |> String.trim_trailing("'")
        if ctx.branch == excluded do
          "branch is '#{ctx.branch}'"
        else
          nil
        end

      # tag != '' (has tag)
      condition == "tag != ''" and ctx.tag == "" ->
        "no tag present"

      # ci == true
      condition == "ci == true" and not ctx.ci ->
        "not running in CI"

      true ->
        nil
    end
  end

  defp topological_sort(tasks) do
    # Build in-degree map
    in_degree = tasks
      |> Enum.map(fn t -> {t.name, length(t.depends_on)} end)
      |> Map.new()

    task_map = tasks |> Enum.map(fn t -> {t.name, t} end) |> Map.new()

    # Kahn's algorithm
    queue = in_degree
      |> Enum.filter(fn {_, d} -> d == 0 end)
      |> Enum.map(fn {name, _} -> name end)

    do_topo_sort(queue, in_degree, task_map, tasks, [])
  end

  defp do_topo_sort([], _in_degree, _task_map, _all_tasks, acc), do: Enum.reverse(acc)
  defp do_topo_sort([name | rest], in_degree, task_map, all_tasks, acc) do
    task = Map.get(task_map, name)
    acc = [task | acc]

    # Find tasks that depend on this one and decrease their in-degree
    {new_queue, new_in_degree} = Enum.reduce(all_tasks, {rest, in_degree}, fn t, {q, deg} ->
      if name in t.depends_on do
        new_deg = Map.update!(deg, t.name, &(&1 - 1))
        if Map.get(new_deg, t.name) == 0 do
          {[t.name | q], new_deg}
        else
          {q, new_deg}
        end
      else
        {q, deg}
      end
    end)

    do_topo_sort(new_queue, new_in_degree, task_map, all_tasks, acc)
  end
end
