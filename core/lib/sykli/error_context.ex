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
          "column" => nil,
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
    |> Enum.filter(&file_exists?(&1.file, workdir))
    |> Enum.map(&enrich_location(&1, workdir))
  end

  defp enrich_location(location, workdir) do
    base = %{
      "file" => location.file,
      "line" => location.line,
      "column" => location.column,
      "message" => location.message
    }

    case build_context(location.file, location.line, workdir) do
      context when context != %{} ->
        Map.put(base, "context", context)

      _ ->
        base
    end
  end

  defp build_context(file, line, workdir) do
    opts = [cd: workdir, timeout: 5_000]
    context = %{}

    # Blame for the specific line
    context =
      case Git.blame_line(file, line, opts) do
        {:ok, blame} ->
          context
          |> Map.put("last_modified_by", blame.author)
          |> Map.put("last_modified_at", blame.date)
          |> Map.put("last_commit", blame.sha)
          |> Map.put("last_commit_message", blame.message)

        _ ->
          context
      end

    # Recent commit count for the file
    context =
      case Git.log_file(file, opts) do
        {:ok, commits} ->
          Map.put(context, "recent_commits", length(commits))

        _ ->
          context
      end

    context
  end

  defp file_exists?(file, workdir) do
    Path.join(workdir, file) |> File.exists?()
  end
end
