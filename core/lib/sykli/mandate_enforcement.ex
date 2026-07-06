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
  Fingerprints repo-root-relative paths so pre-existing dirty files cannot
  hide task writes by staying in the dirty set before and after execution.
  """
  def path_fingerprints(workdir, paths) do
    with {:ok, root} <- repo_root(workdir) do
      paths
      |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
        case path_fingerprint(root, path) do
          {:ok, fingerprint} -> {:cont, {:ok, Map.put(acc, path, fingerprint)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def changed_paths(before_fingerprints, after_fingerprints) do
    before_fingerprints = before_fingerprints || %{}
    after_fingerprints = after_fingerprints || %{}

    before_fingerprints
    |> Map.keys()
    |> Kernel.++(Map.keys(after_fingerprints))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(before_fingerprints, &1) != Map.get(after_fingerprints, &1)))
  end

  def changed_line_count(before_fingerprints, after_fingerprints) do
    before_fingerprints = before_fingerprints || %{}
    after_fingerprints = after_fingerprints || %{}

    before_fingerprints
    |> Map.keys()
    |> Kernel.++(Map.keys(after_fingerprints))
    |> Enum.uniq()
    |> Enum.map(
      &line_change_count(Map.get(before_fingerprints, &1), Map.get(after_fingerprints, &1))
    )
    |> Enum.sum()
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

  defp repo_root(workdir) do
    case Sykli.Git.run(["rev-parse", "--show-toplevel"], cd: workdir) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_fingerprint(root, rel_path) do
    path = Path.join(root, rel_path)

    cond do
      File.regular?(path) ->
        case File.read(path) do
          {:ok, content} ->
            {:ok,
             %{
               type: :regular,
               sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
               content: content
             }}

          {:error, reason} ->
            {:error, {:path_fingerprint_failed, rel_path, reason}}
        end

      File.exists?(path) ->
        {:ok, %{type: :non_regular}}

      true ->
        {:ok, %{type: :missing}}
    end
  end

  defp line_change_count(nil, %{content: content}), do: line_count(content)
  defp line_change_count(%{content: content}, nil), do: line_count(content)
  defp line_change_count(same, same), do: 0

  defp line_change_count(%{content: before}, %{content: after_}) do
    before
    |> lines()
    |> List.myers_difference(lines(after_))
    |> Enum.map(fn
      {:eq, _lines} -> 0
      {:ins, lines} -> length(lines)
      {:del, lines} -> length(lines)
    end)
    |> Enum.sum()
  end

  defp line_change_count(_before, _after), do: 1

  defp line_count(content), do: content |> lines() |> length()

  defp lines(""), do: []
  defp lines(content), do: String.split(content, "\n", trim: false)

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
