defmodule Sykli.Delta do
  @moduledoc """
  Determines which tasks are affected by git changes.

  Uses git diff to find changed files, then matches them against
  task inputs (mounts) to find affected tasks. Also includes
  all tasks that depend on affected tasks (transitive dependents).
  """

  @type affected_task :: %{
          name: String.t(),
          reason: :direct | :dependent,
          files: [String.t()],
          depends_on: String.t() | nil
        }

  @doc """
  Returns list of task names affected by git changes.

  Options:
    - from: base branch/commit to compare against (default: "HEAD")
    - path: project path (default: ".")
  """
  def affected_tasks(tasks, opts \\ []) do
    case affected_tasks_detailed(tasks, opts) do
      {:ok, details} -> {:ok, Enum.map(details, & &1.name)}
      error -> error
    end
  end

  @doc """
  Returns detailed info about affected tasks including WHY they're affected.

  Returns list of maps with:
    - name: task name
    - reason: :direct (files changed) or :dependent (depends on affected task)
    - files: list of changed files that triggered this task (empty for dependents)
    - depends_on: name of affected task this depends on (nil for direct)
  """
  def affected_tasks_detailed(tasks, opts \\ []) do
    from = Keyword.get(opts, :from, "HEAD")
    path = Keyword.get(opts, :path, ".")

    case get_changed_files(from, path) do
      {:ok, []} ->
        {:ok, []}

      {:ok, changed_files} ->
        # Find directly affected tasks with file details
        directly_affected = find_directly_affected_detailed(tasks, changed_files, path)

        # Add transitive dependents with dependency info
        all_affected = add_dependents_detailed(directly_affected, tasks)

        {:ok, all_affected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the list of changed files from git.
  """
  def get_changed_files(from, path) do
    get_changed_files_impl(from, path)
  end

  @doc """
  Filters a task list to only include affected tasks.
  """
  def filter_tasks(tasks, affected_names) do
    affected_set = MapSet.new(affected_names)
    Enum.filter(tasks, fn task -> MapSet.member?(affected_set, task.name) end)
  end

  # Get list of changed files from git (relative to project path)
  defp get_changed_files_impl(from, path) do
    # First check if we're in a git repo
    case System.cmd("git", ["rev-parse", "--git-dir"], cd: path, stderr_to_stdout: true) do
      {_, 0} ->
        get_git_changes(from, path)

      {_, _} ->
        {:error, {:not_a_git_repo, path}}
    end
  end

  defp get_git_changes(from, path) do
    # Use --relative to get paths relative to the project directory
    case System.cmd("git", ["diff", "--name-only", "--relative", from],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files = output |> String.trim() |> String.split("\n", trim: true)

        # Also get untracked files (relative to current directory)
        case System.cmd("git", ["ls-files", "--others", "--exclude-standard"],
               cd: path,
               stderr_to_stdout: true
             ) do
          {untracked, 0} ->
            untracked_files = untracked |> String.trim() |> String.split("\n", trim: true)
            {:ok, Enum.uniq(files ++ untracked_files)}

          _ ->
            {:ok, files}
        end

      {error, code} ->
        cond do
          String.contains?(error, "unknown revision") ->
            {:error, {:unknown_ref, from}}

          String.contains?(error, "bad revision") ->
            {:error, {:bad_revision, from}}

          true ->
            {:error, {:git_failed, error, code}}
        end
    end
  end

  # Find tasks directly affected by changed files (with details)
  defp find_directly_affected_detailed(tasks, changed_files, workdir) do
    abs_workdir = Path.expand(workdir)

    tasks
    |> Enum.map(fn task ->
      matching_files = get_matching_files(task, changed_files, abs_workdir)

      if matching_files != [] do
        %{name: task.name, reason: :direct, files: matching_files, depends_on: nil}
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Get list of changed files that match a task's inputs
  defp get_matching_files(task, changed_files, workdir) do
    input_paths = get_task_input_paths(task, workdir)

    if input_paths == [] do
      # Check if task has inputs field (glob patterns)
      case task.inputs do
        nil -> []
        [] -> []
        patterns -> get_files_matching_patterns(changed_files, patterns)
      end
    else
      # Get changed files under any input path
      Enum.filter(changed_files, fn file ->
        file_under_any_path?(file, input_paths, workdir)
      end)
    end
  end

  # Get files matching any of the patterns
  defp get_files_matching_patterns(files, patterns) do
    Enum.filter(files, fn file ->
      Enum.any?(patterns, fn pattern -> match_glob?(file, pattern) end)
    end)
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

  # Simple glob matching (supports * and **)
  defp match_glob?(file, pattern) do
    regex_pattern =
      pattern
      |> Regex.escape()
      # **/ at start should match zero or more directories
      |> String.replace("\\*\\*/", "(.*/)?")
      # ** elsewhere matches anything
      |> String.replace("\\*\\*", ".*")
      # * matches anything except /
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/^#{regex_pattern}$/, file)
  end

  # Add all tasks that depend on affected tasks (transitively) - with details
  defp add_dependents_detailed(directly_affected, tasks) do
    affected_names = MapSet.new(Enum.map(directly_affected, & &1.name))
    reverse_deps = build_reverse_deps(tasks)

    # BFS to find dependents with tracking of which task triggered them
    dependent_details =
      find_dependents_with_reasons(directly_affected, affected_names, reverse_deps)

    directly_affected ++ dependent_details
  end

  defp find_dependents_with_reasons(queue, seen, reverse_deps) do
    do_find_dependents_with_reasons(queue, seen, reverse_deps, [])
  end

  defp do_find_dependents_with_reasons([], _seen, _reverse_deps, acc) do
    Enum.reverse(acc)
  end

  defp do_find_dependents_with_reasons([current | rest], seen, reverse_deps, acc) do
    dependents = Map.get(reverse_deps, current.name, [])

    {new_details, new_seen} =
      Enum.reduce(dependents, {[], seen}, fn dep_name, {details, seen_acc} ->
        if MapSet.member?(seen_acc, dep_name) do
          {details, seen_acc}
        else
          detail = %{
            name: dep_name,
            reason: :dependent,
            files: [],
            depends_on: current.name
          }

          {[detail | details], MapSet.put(seen_acc, dep_name)}
        end
      end)

    do_find_dependents_with_reasons(
      rest ++ Enum.reverse(new_details),
      new_seen,
      reverse_deps,
      new_details ++ acc
    )
  end

  defp build_reverse_deps(tasks) do
    Enum.reduce(tasks, %{}, fn task, acc ->
      (task.depends_on || [])
      |> Enum.reduce(acc, fn dep, inner_acc ->
        Map.update(inner_acc, dep, [task.name], &[task.name | &1])
      end)
    end)
  end

  @doc """
  Formats error tuples into human-readable messages.
  """
  def format_error({:not_a_git_repo, path}) do
    "Not a git repository: #{path}"
  end

  def format_error({:unknown_ref, ref}) do
    "Unknown git reference: #{ref}\nHint: Make sure the branch or commit exists."
  end

  def format_error({:bad_revision, ref}) do
    "Bad revision: #{ref}\nHint: Check that '#{ref}' is a valid branch, tag, or commit."
  end

  def format_error({:git_failed, message, _code}) do
    "Git command failed: #{String.trim(message)}"
  end

  def format_error(other) do
    "Error: #{inspect(other)}"
  end
end
