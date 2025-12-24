defmodule Sykli.Delta do
  @moduledoc """
  Determines which tasks are affected by git changes.

  Uses git diff to find changed files, then matches them against
  task inputs (mounts) to find affected tasks. Also includes
  all tasks that depend on affected tasks (transitive dependents).
  """

  @doc """
  Returns list of task names affected by git changes.

  Options:
    - from: base branch/commit to compare against (default: "HEAD")
    - path: project path (default: ".")
  """
  def affected_tasks(tasks, opts \\ []) do
    from = Keyword.get(opts, :from, "HEAD")
    path = Keyword.get(opts, :path, ".")

    case get_changed_files(from, path) do
      {:ok, []} ->
        # No changes, nothing affected
        {:ok, []}

      {:ok, changed_files} ->
        # Find directly affected tasks
        directly_affected = find_directly_affected(tasks, changed_files, path)

        # Add transitive dependents
        all_affected = add_dependents(directly_affected, tasks)

        {:ok, all_affected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Filters a task list to only include affected tasks.
  """
  def filter_tasks(tasks, affected_names) do
    affected_set = MapSet.new(affected_names)
    Enum.filter(tasks, fn task -> MapSet.member?(affected_set, task.name) end)
  end

  # Get list of changed files from git (relative to project path)
  defp get_changed_files(from, path) do
    # Use --relative to get paths relative to the project directory
    case System.cmd("git", ["diff", "--name-only", "--relative", from], cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        files = output |> String.trim() |> String.split("\n", trim: true)

        # Also get untracked files (relative to current directory)
        case System.cmd("git", ["ls-files", "--others", "--exclude-standard"], cd: path, stderr_to_stdout: true) do
          {untracked, 0} ->
            untracked_files = untracked |> String.trim() |> String.split("\n", trim: true)
            {:ok, Enum.uniq(files ++ untracked_files)}

          _ ->
            {:ok, files}
        end

      {error, _} ->
        {:error, {:git_failed, error}}
    end
  end

  # Find tasks directly affected by changed files
  defp find_directly_affected(tasks, changed_files, workdir) do
    abs_workdir = Path.expand(workdir)

    tasks
    |> Enum.filter(fn task ->
      task_affected?(task, changed_files, abs_workdir)
    end)
    |> Enum.map(& &1.name)
  end

  # Check if a task is affected by any changed file
  defp task_affected?(task, changed_files, workdir) do
    # Get all input paths from task mounts
    input_paths = get_task_input_paths(task, workdir)

    # If task has no mounts, it's not affected by file changes
    # (it either has no inputs or uses inputs field)
    if input_paths == [] do
      # Check if task has inputs field (glob patterns)
      case task.inputs do
        nil -> false
        [] -> false
        patterns -> any_file_matches_patterns?(changed_files, patterns)
      end
    else
      # Check if any changed file is under any input path
      Enum.any?(changed_files, fn file ->
        file_under_any_path?(file, input_paths, workdir)
      end)
    end
  end

  # Get all input paths from task mounts
  defp get_task_input_paths(task, workdir) do
    (task.mounts || [])
    |> Enum.filter(fn mount ->
      # Only directory mounts are inputs (not caches)
      mount_type = mount[:type] || mount["type"]
      mount_type == :directory or mount_type == "directory"
    end)
    |> Enum.map(fn mount ->
      # Get the source path from mount
      resource = mount[:resource] || mount["resource"]

      case resource do
        "src:" <> path -> Path.expand(path, workdir)
        path -> Path.expand(path, workdir)
      end
    end)
  end

  # Check if a file is under any of the input paths
  defp file_under_any_path?(file, paths, workdir) do
    abs_file = Path.expand(file, workdir)

    Enum.any?(paths, fn path ->
      String.starts_with?(abs_file, path) or
        String.starts_with?(Path.expand(file, workdir), path)
    end)
  end

  # Check if any file matches any glob pattern
  defp any_file_matches_patterns?(files, patterns) do
    Enum.any?(files, fn file ->
      Enum.any?(patterns, fn pattern ->
        match_glob?(file, pattern)
      end)
    end)
  end

  # Simple glob matching (supports * and **)
  defp match_glob?(file, pattern) do
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/^#{regex_pattern}$/, file)
  end

  # Add all tasks that depend on affected tasks (transitively)
  defp add_dependents(affected_names, tasks) do
    affected_set = MapSet.new(affected_names)

    # Build reverse dependency map: task -> tasks that depend on it
    reverse_deps = build_reverse_deps(tasks)

    # BFS to find all dependents
    find_all_dependents(affected_set, reverse_deps)
  end

  defp build_reverse_deps(tasks) do
    Enum.reduce(tasks, %{}, fn task, acc ->
      (task.depends_on || [])
      |> Enum.reduce(acc, fn dep, inner_acc ->
        Map.update(inner_acc, dep, [task.name], &[task.name | &1])
      end)
    end)
  end

  defp find_all_dependents(affected_set, reverse_deps) do
    do_find_dependents(MapSet.to_list(affected_set), affected_set, reverse_deps)
  end

  defp do_find_dependents([], affected_set, _reverse_deps) do
    MapSet.to_list(affected_set)
  end

  defp do_find_dependents([current | rest], affected_set, reverse_deps) do
    dependents = Map.get(reverse_deps, current, [])

    new_dependents =
      Enum.reject(dependents, &MapSet.member?(affected_set, &1))

    new_affected = Enum.reduce(new_dependents, affected_set, &MapSet.put(&2, &1))

    do_find_dependents(rest ++ new_dependents, new_affected, reverse_deps)
  end
end
