defmodule Sykli.Query.Coverage do
  @moduledoc """
  Coverage queries: which tasks cover which files/patterns.
  """

  alias Sykli.Graph.Task

  @spec execute(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def execute(pattern, path) do
    with {:ok, graph} <- load_graph(path) do
      tasks = find_covering_tasks(pattern, graph)

      {:ok,
       %{
         type: :coverage,
         data: %{
           pattern: pattern,
           tasks: tasks,
           total: length(tasks)
         },
         metadata: metadata("coverage for #{pattern}")
       }}
    end
  end

  defp find_covering_tasks(pattern, graph) do
    # Pre-compile all unique cover globs to avoid repeated regex compilation
    compiled_globs =
      graph
      |> Enum.flat_map(fn {_name, task} -> Task.semantic(task).covers || [] end)
      |> Enum.uniq()
      |> Map.new(fn glob -> {glob, compile_glob(glob)} end)

    graph
    |> Enum.filter(fn {_name, task} ->
      covers = Task.semantic(task).covers || []
      Enum.any?(covers, &pattern_match?(pattern, &1, compiled_globs))
    end)
    |> Enum.map(fn {name, task} ->
      semantic = Task.semantic(task)

      %{
        name: name,
        covers: semantic.covers || [],
        intent: semantic.intent,
        criticality: if(semantic.criticality, do: Atom.to_string(semantic.criticality))
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  # Check if a user pattern matches a task's cover glob.
  # "auth" matches "src/auth/*" (substring)
  # "src/auth/login.ts" matches "src/auth/*" (glob)
  defp pattern_match?(user_pattern, cover_glob, compiled_globs) do
    String.contains?(cover_glob, user_pattern) or
      case Map.get(compiled_globs, cover_glob) do
        {:ok, regex} -> Regex.match?(regex, user_pattern)
        :error -> false
      end
  end

  defp compile_glob(glob) do
    regex_str =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    case Regex.compile("^#{regex_str}$") do
      {:ok, regex} -> {:ok, regex}
      _ -> :error
    end
  end

  defp load_graph(path) do
    alias Sykli.{Detector, Graph}

    with {:ok, sdk_file} <- Detector.find(path),
         {:ok, json} <- Detector.emit(sdk_file),
         {:ok, graph} <- Graph.parse(json) do
      {:ok, Graph.expand_matrix(graph)}
    end
  end

  defp metadata(query) do
    %{query: query, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
  end
end
