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

    task = Task.async(fn ->
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
  """
  def sha(opts \\ []) do
    case run(["rev-parse", "--short", "HEAD"], opts) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      error -> error
    end
  end

  @doc """
  Get the current branch name.

  Returns `nil` for detached HEAD state.
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
  """
  def remote_url(opts \\ []) do
    case run(["remote", "get-url", "origin"], opts) do
      {:ok, url} -> {:ok, String.trim(url)}
      {:error, {:git_failed, _, _}} -> {:ok, nil}
      error -> error
    end
  end

  @doc """
  Check if the given path is inside a git repository.
  """
  def repo?(path) do
    case run(["rev-parse", "--git-dir"], cd: path) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
