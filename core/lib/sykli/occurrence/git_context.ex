defmodule Sykli.Occurrence.GitContext do
  @moduledoc """
  Collects git context for occurrence reports.

  Gathers SHA, branch, recent commits, and changed files using
  `Sykli.Git.run/2`. Degrades gracefully when not in a git repo.
  """

  alias Sykli.Git

  @doc """
  Collects git context from the given workdir.

  Returns a map with sha, branch, recent_commits, and changed_files.
  Returns a minimal map if git is unavailable.
  """
  @spec collect(String.t()) :: map()
  def collect(workdir) do
    opts = [cd: workdir]

    %{
      "sha" => get_sha(opts),
      "branch" => get_branch(opts),
      "remote_url" => get_remote_url(workdir),
      "recent_commits" => recent_commits(workdir),
      "changed_files" => changed_files(workdir)
    }
  end

  @doc """
  Returns recent commits as a list of maps.
  """
  @spec recent_commits(String.t(), pos_integer()) :: [map()]
  def recent_commits(workdir, limit \\ 5) do
    format = "%H%n%s%n%an"
    args = ["log", "--format=#{format}", "-n", to_string(limit)]

    case Git.run(args, cd: workdir) do
      {:ok, output} ->
        output
        |> String.trim()
        |> parse_commits()

      _ ->
        []
    end
  end

  defp get_sha(opts) do
    case Git.sha(opts) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end

  defp get_branch(opts) do
    case Git.branch(opts) do
      {:ok, branch} -> branch
      _ -> nil
    end
  end

  defp get_remote_url(workdir) do
    case Git.run(["remote", "get-url", "origin"], cd: workdir) do
      {:ok, url} -> url |> String.trim() |> normalize_remote_url()
      _ -> nil
    end
  end

  @doc """
  Normalizes a git remote URL to HTTPS format for SLSA provenance.

  Converts SSH URLs like `git@github.com:org/repo.git` to
  `https://github.com/org/repo`. Strips trailing `.git`.
  """
  @spec normalize_remote_url(String.t()) :: String.t()
  def normalize_remote_url(url) do
    url
    |> convert_ssh_to_https()
    |> String.trim_trailing(".git")
  end

  defp convert_ssh_to_https("git@" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [host, path] -> "https://#{host}/#{path}"
      _ -> "https://#{rest}"
    end
  end

  defp convert_ssh_to_https("ssh://git@" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [host_port, path] ->
        host = host_port |> String.split(":") |> List.first()
        "https://#{host}/#{path}"

      _ ->
        "https://#{rest}"
    end
  end

  defp convert_ssh_to_https(url), do: url

  defp changed_files(workdir) do
    # Get uncommitted changes (staged + unstaged + untracked)
    case Git.run(["status", "--porcelain"], cd: workdir) do
      {:ok, ""} ->
        []

      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          # Format: "XY filename" or "XY filename -> renamed"
          line
          |> String.slice(3..-1//1)
          |> String.split(" -> ")
          |> List.last()
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_commits(""), do: []

  defp parse_commits(output) do
    output
    |> String.split("\n")
    |> Enum.chunk_every(3)
    |> Enum.flat_map(fn
      [sha, message, author] ->
        [
          %{
            "sha" => String.slice(sha, 0, 7),
            "message" => message,
            "author" => author
          }
        ]

      _ ->
        []
    end)
  end
end
