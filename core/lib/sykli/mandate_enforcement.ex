defmodule Sykli.MandateEnforcement do
  @moduledoc """
  Git-backed verification mechanics for v5 mandate enforcement.

  Snapshot parsing and scope matching are pure functions; the git-facing
  helpers run through `Sykli.Git` so a hung git cannot stall the executor.
  Every git failure surfaces as an explicit `{:error, reason}` — mandate
  verification never fails open. The executor owns policy (what a failure
  means); this module owns mechanics (what changed, does it match scope).
  """

  @doc """
  Whether `workdir` is inside a git work tree.

  Returns `{:ok, boolean}` or `{:error, reason}` (e.g. git timeout).
  """
  def work_tree?(workdir) do
    case Sykli.Git.run(["rev-parse", "--is-inside-work-tree"], cd: workdir) do
      {:ok, output} -> {:ok, String.trim(output) == "true"}
      {:error, {:git_failed, _output, _code}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The workdir's path relative to the repository root, as git reports it
  (`""` when the workdir is the root, `"sub/dir/"` otherwise). Porcelain
  paths are repo-root-relative; stripping this prefix rebases them to the
  workdir without touching the filesystem — immune to symlinked tmp dirs
  and deleted files alike.
  """
  def workdir_prefix(workdir) do
    case Sykli.Git.run(["rev-parse", "--show-prefix"], cd: workdir) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Set of repo-root-relative paths git reports as changed (staged, unstaged,
  and untracked). Rename/copy entries contribute both sides.
  """
  def status_paths(workdir) do
    case Sykli.Git.run(["status", "--porcelain=v1", "-z"], cd: workdir) do
      {:ok, output} -> {:ok, parse_porcelain(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses `git status --porcelain=v1 -z` output into a set of paths.

  Rename and copy entries emit a second NUL-separated record carrying the
  origin path with no `XY ` prefix; both sides are changed paths. Pure.
  """
  def parse_porcelain(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> collect_records([])
    |> MapSet.new()
  end

  defp collect_records([], acc), do: acc

  defp collect_records([record | rest], acc) when byte_size(record) > 3 do
    status = binary_part(record, 0, 2)
    path = binary_part(record, 3, byte_size(record) - 3)

    if String.contains?(status, ["R", "C"]) do
      case rest do
        [origin | remaining] -> collect_records(remaining, [origin, path | acc])
        [] -> [path | acc]
      end
    else
      collect_records(rest, [path | acc])
    end
  end

  defp collect_records([_short | rest], acc), do: collect_records(rest, acc)

  @doc """
  Whether `rel_path` matches any of the scope `patterns`.

  Matching is lexical — the pattern is compiled to a regex and tested
  against the path string, so files the task deleted or renamed away
  still match their scope. Supports `**` (crosses directories), `*`
  (within one segment), and `?` (single character). Pure.
  """
  def scope_match?(patterns, rel_path) when is_list(patterns) do
    Enum.any?(patterns, &scope_match?(&1, rel_path))
  end

  def scope_match?(pattern, rel_path) when is_binary(pattern) do
    Regex.match?(compile_pattern(pattern), rel_path)
  end

  def scope_match?(_pattern, _rel_path), do: false

  @doc """
  Compiles a scope glob into an anchored regex. Pure.
  """
  def compile_pattern(pattern) do
    regex =
      pattern
      |> String.split("**", trim: false)
      |> Enum.map(&compile_segment/1)
      |> Enum.join(".*")

    Regex.compile!("^" <> regex <> "$")
  end

  defp compile_segment(segment) do
    segment
    |> String.graphemes()
    |> Enum.map(fn
      "*" -> "[^/]*"
      "?" -> "[^/]"
      char -> Regex.escape(char)
    end)
    |> Enum.join()
  end

  @doc """
  Total changed line count for the work tree: unstaged + staged numstat
  plus line counts of untracked files. Callers subtract a preflight
  baseline to charge only the task's own changes against its budget.
  """
  def diff_lines(workdir) do
    with {:ok, unstaged} <- numstat_lines(workdir, []),
         {:ok, staged} <- numstat_lines(workdir, ["--cached"]),
         {:ok, untracked} <- untracked_lines(workdir) do
      {:ok, unstaged + staged + untracked}
    end
  end

  defp numstat_lines(workdir, extra_args) do
    case Sykli.Git.run(["diff", "--numstat"] ++ extra_args, cd: workdir) do
      {:ok, output} ->
        total =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&numstat_line_count/1)
          |> Enum.sum()

        {:ok, total}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp numstat_line_count(line) do
    case String.split(line, "\t") do
      [added, deleted | _] -> parse_numstat(added) + parse_numstat(deleted)
      _ -> 0
    end
  end

  defp parse_numstat("-"), do: 0

  defp parse_numstat(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp untracked_lines(workdir) do
    case Sykli.Git.run(["ls-files", "--others", "--exclude-standard"], cd: workdir) do
      {:ok, output} ->
        total =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&file_line_count(Path.join(workdir, &1)))
          |> Enum.sum()

        {:ok, total}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_line_count(path) do
    if File.regular?(path) do
      path
      |> File.stream!(:line)
      |> Enum.count()
    else
      0
    end
  rescue
    _ -> 0
  end
end
