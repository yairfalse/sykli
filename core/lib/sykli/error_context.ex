defmodule Sykli.ErrorContext do
  @moduledoc """
  Enriches parsed error locations with git context.

  Orchestrates `ErrorParser` (parse file:line from output) and `Git`
  (blame/log for each location) into a single enriched locations list
  suitable for occurrence.json.
  """

  alias Sykli.ErrorParser
  alias Sykli.Git

  @doc """
  Parse locations from command output and enrich with git context.

  Returns a list of location maps with optional `context` field containing
  git blame/log information. Locations for files that don't exist on disk
  are filtered out.

  ## Example return

      [
        %{
          "file" => "src/auth/login.ts",
          "line" => 42,
          "message" => "expected 200 got 401",
          "context" => %{
            "last_modified_by" => "alice",
            "last_modified_at" => "2024-01-15T08:30:00Z",
            "last_commit" => "abc1234",
            "last_commit_message" => "refactor token validation",
            "recent_commits" => 3
          }
        }
      ]
  """
  @spec enrich(String.t() | nil, String.t()) :: [map()]
  def enrich(nil, _workdir), do: []
  def enrich("", _workdir), do: []

  def enrich(output, workdir) do
    output
    |> ErrorParser.parse()
    |> enrich_locations(workdir)
  end

  @doc """
  Enrich pre-parsed locations with git context.

  Use this when locations have already been parsed (e.g., from `Error.locations`)
  to avoid re-parsing the same output.
  """
  @spec enrich_locations([ErrorParser.location()], String.t()) :: [map()]
  def enrich_locations([], _workdir), do: []

  def enrich_locations(locations, workdir) do
    locations
    |> Enum.map(&normalize_path(&1, workdir))
    |> Enum.filter(&file_exists?(&1.file, workdir))
    |> Enum.map(&enrich_location(&1, workdir))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp enrich_location(location, workdir) do
    base =
      %{
        "file" => location.file,
        "line" => location.line
      }
      |> maybe_put("column", location.column)
      |> maybe_put("message", location.message)

    case build_context(location.file, location.line, workdir) do
      context when context != %{} ->
        Map.put(base, "context", context)

      _ ->
        base
    end
  end

  defp build_context(file, line, workdir) do
    opts = [cd: workdir, timeout: 5_000]
    outer_timeout = opts[:timeout] + 5_000

    # Run blame and log in parallel
    blame_task = Task.async(fn -> Git.blame_line(file, line, opts) end)
    log_task = Task.async(fn -> Git.log_file(file, opts) end)

    blame_result = Task.yield(blame_task, outer_timeout) || Task.shutdown(blame_task)
    log_result = Task.yield(log_task, outer_timeout) || Task.shutdown(log_task)

    context = %{}

    context =
      case blame_result do
        {:ok, {:ok, blame}} ->
          context
          |> Map.put("last_modified_by", blame.author)
          |> Map.put("last_modified_at", blame.date)
          |> Map.put("last_commit", blame.sha)
          |> Map.put("last_commit_message", blame.message)

        _ ->
          context
      end

    context =
      case log_result do
        {:ok, {:ok, commits}} ->
          Map.put(context, "recent_commits", length(commits))

        _ ->
          context
      end

    context
  end

  # Convert absolute paths to relative if they're within workdir.
  # Discard absolute paths outside workdir.
  defp normalize_path(%{file: file} = loc, workdir) do
    if Path.type(file) == :absolute do
      abs_workdir = Path.expand(workdir)

      if String.starts_with?(file, abs_workdir <> "/") do
        %{loc | file: Path.relative_to(file, abs_workdir)}
      else
        # Absolute path outside workdir — mark for filtering
        %{loc | file: :skip}
      end
    else
      loc
    end
  end

  defp file_exists?(:skip, _workdir), do: false

  defp file_exists?(file, workdir) do
    Path.join(workdir, file) |> File.exists?()
  end
end
