defmodule Sykli.Git do
  @moduledoc """
  Git command utilities with timeout support.

  All git commands are wrapped in a Task with configurable timeout
  to prevent hangs on NFS mounts, large repos, or network issues.
  """

  @default_timeout 10_000

  @doc """
  Run a git command with timeout.

  ## Options
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, output}` - command succeeded (exit code 0)
    - `{:error, {:git_failed, output, exit_code}}` - command failed
    - `{:error, {:git_timeout, args}}` - command timed out

  ## Examples

      iex> Sykli.Git.run(["rev-parse", "HEAD"], cd: "/path/to/repo")
      {:ok, "abc1234...\\n"}

      iex> Sykli.Git.run(["diff", "--name-only", "HEAD~10"], cd: path, timeout: 30_000)
      {:ok, "file1.ex\\nfile2.ex\\n"}
  """
  def run(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cd = Keyword.get(opts, :cd, ".")

    task =
      Task.async(fn ->
        System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, code}} ->
        {:error, {:git_failed, output, code}}

      nil ->
        {:error, {:git_timeout, args}}
    end
  end

  @doc """
  Get the current commit SHA (short form).

  ## Options
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, sha}` - the short SHA string
    - `{:error, {:git_failed, output, exit_code}}` - command failed
    - `{:error, {:git_timeout, args}}` - command timed out
  """
  def sha(opts \\ []) do
    case run(["rev-parse", "--short", "HEAD"], opts) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      error -> error
    end
  end

  @doc """
  Get the current branch name.

  ## Options
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, branch_name}` - the branch name string
    - `{:ok, nil}` - detached HEAD state (no branch)
    - `{:error, {:git_failed, output, exit_code}}` - command failed
    - `{:error, {:git_timeout, args}}` - command timed out
  """
  def branch(opts \\ []) do
    case run(["rev-parse", "--abbrev-ref", "HEAD"], opts) do
      {:ok, branch} ->
        branch = String.trim(branch)
        {:ok, if(branch == "HEAD", do: nil, else: branch)}

      error ->
        error
    end
  end

  @doc """
  Check if the working directory is dirty (has uncommitted changes).

  ## Options
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, true}` - working directory has uncommitted changes
    - `{:ok, false}` - working directory is clean
    - `{:error, {:git_failed, output, exit_code}}` - command failed
    - `{:error, {:git_timeout, args}}` - command timed out
  """
  def dirty?(opts \\ []) do
    case run(["status", "--porcelain"], opts) do
      {:ok, ""} -> {:ok, false}
      {:ok, _} -> {:ok, true}
      error -> error
    end
  end

  @doc """
  Get the remote URL for origin.

  ## Options
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, url}` - the remote URL string
    - `{:ok, nil}` - no remote named "origin" configured
    - `{:error, {:git_timeout, args}}` - command timed out
  """
  def remote_url(opts \\ []) do
    case run(["remote", "get-url", "origin"], opts) do
      {:ok, url} ->
        {:ok, String.trim(url)}

      {:error, {:git_timeout, _}} = error ->
        error

      {:error, {:git_failed, _, _}} ->
        {:ok, nil}
    end
  end

  @doc """
  Check if the given path is inside a git repository.

  ## Options
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, true}` - path is inside a git repository
    - `{:ok, false}` - path is not inside a git repository
    - `{:error, {:git_timeout, args}}` - command timed out
  """
  def repo?(opts \\ []) do
    case run(["rev-parse", "--git-dir"], opts) do
      {:ok, _} ->
        {:ok, true}

      {:error, {:git_timeout, _}} = error ->
        error

      {:error, {:git_failed, _, _}} ->
        {:ok, false}
    end
  end

  @doc """
  Recent commits touching a file (last 5 by default).

  ## Options
    - `:limit` - max commits to return (default: 5)
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, [%{sha: String.t(), author: String.t(), date: String.t(), message: String.t()}]}`
    - `{:error, term()}`
  """
  @spec log_file(String.t(), keyword()) ::
          {:ok, [%{sha: String.t(), author: String.t(), date: String.t(), message: String.t()}]}
          | {:error, term()}
  def log_file(file, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    # Use null byte separator — safe against any field content
    case run(["log", "--format=%H%x00%an%x00%aI%x00%s", "-#{limit}", "--", file], opts) do
      {:ok, output} ->
        commits =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&parse_log_line/1)

        {:ok, commits}

      {:error, _} = error ->
        error
    end
  end

  defp parse_log_line(line) do
    case String.split(line, "\0", parts: 4) do
      [sha, author, date, message] ->
        [%{sha: sha, author: author, date: date, message: message}]

      _ ->
        []
    end
  end

  @doc """
  Blame info for a specific line of a file.

  Uses `git blame --porcelain` for machine-parseable output.

  ## Options
    - `:timeout` - milliseconds before killing the command (default: 10_000)
    - `:cd` - directory to run the command in (default: current directory)

  ## Returns
    - `{:ok, %{sha: String.t(), author: String.t(), date: String.t(), message: String.t()}}`
    - `{:error, term()}`
  """
  @spec blame_line(String.t(), pos_integer(), keyword()) ::
          {:ok, %{sha: String.t(), author: String.t(), date: String.t(), message: String.t()}}
          | {:error, term()}
  def blame_line(file, line, opts \\ []) do
    case run(["blame", "-L", "#{line},#{line}", "--porcelain", file], opts) do
      {:ok, output} ->
        parse_porcelain_blame(output)

      {:error, _} = error ->
        error
    end
  end

  defp parse_porcelain_blame(output) do
    lines = String.split(output, "\n")

    sha =
      case lines do
        [first | _] -> first |> String.split(" ") |> hd()
        _ -> nil
      end

    fields =
      Map.new(lines, fn line ->
        case String.split(line, " ", parts: 2) do
          [key, value] -> {key, value}
          _ -> {"", line}
        end
      end)

    author = Map.get(fields, "author", "unknown")

    # Convert author-time (unix) to ISO 8601
    date =
      case Map.get(fields, "author-time") do
        nil ->
          "unknown"

        timestamp_str ->
          case Integer.parse(timestamp_str) do
            {ts, _} -> DateTime.from_unix!(ts) |> DateTime.to_iso8601()
            :error -> "unknown"
          end
      end

    message = Map.get(fields, "summary", "")

    if sha do
      {:ok, %{sha: sha, author: author, date: date, message: message}}
    else
      {:error, :parse_failed}
    end
  end
end
