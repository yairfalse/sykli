defmodule Sykli.GitContext do
  @moduledoc """
  Detects and parses git repository context.

  Used by K8s target to clone source code into Jobs.

  ## Example

      ctx = GitContext.detect(".")
      # => %{
      #   url: "https://github.com/org/repo.git",
      #   branch: "main",
      #   sha: "abc123def456...",
      #   dirty: false
      # }
  """

  @type t :: %{
          url: String.t() | nil,
          branch: String.t() | nil,
          sha: String.t(),
          dirty: boolean()
        }

  @type parsed_url :: %{
          protocol: :https | :ssh,
          host: String.t(),
          owner: String.t(),
          repo: String.t()
        }

  # ─────────────────────────────────────────────────────────────────────────────
  # DETECTION
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Detect git context from a working directory.

  Returns a map with:
  - `:url` - Remote URL (origin)
  - `:branch` - Current branch name
  - `:sha` - Current commit SHA
  - `:dirty` - Whether there are uncommitted changes

  Returns `{:error, :not_a_git_repo}` if the directory is not a git repository.
  """
  @spec detect(Path.t()) :: t() | {:error, :not_a_git_repo}
  def detect(workdir) do
    abs_path = Path.expand(workdir)

    with {:ok, sha} <- git_sha(abs_path),
         {:ok, branch} <- git_branch(abs_path),
         {:ok, url} <- git_remote_url(abs_path),
         {:ok, dirty} <- git_dirty?(abs_path) do
      %{
        url: url,
        branch: branch,
        sha: sha,
        dirty: dirty
      }
    else
      {:error, :not_a_git_repo} -> {:error, :not_a_git_repo}
      _ -> {:error, :not_a_git_repo}
    end
  end

  defp git_sha(workdir) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workdir, stderr_to_stdout: true) do
      {sha, 0} -> {:ok, String.trim(sha)}
      _ -> {:error, :not_a_git_repo}
    end
  end

  defp git_branch(workdir) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: workdir,
           stderr_to_stdout: true
         ) do
      {branch, 0} ->
        branch = String.trim(branch)
        # HEAD means detached
        {:ok, if(branch == "HEAD", do: nil, else: branch)}

      _ ->
        {:ok, nil}
    end
  end

  defp git_remote_url(workdir) do
    case System.cmd("git", ["remote", "get-url", "origin"], cd: workdir, stderr_to_stdout: true) do
      {url, 0} -> {:ok, String.trim(url)}
      _ -> {:ok, nil}
    end
  end

  defp git_dirty?(workdir) do
    case System.cmd("git", ["status", "--porcelain"], cd: workdir, stderr_to_stdout: true) do
      {"", 0} -> {:ok, false}
      {_, 0} -> {:ok, true}
      _ -> {:error, :not_a_git_repo}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # URL PARSING
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Parse a git remote URL into its components.

  Handles both HTTPS and SSH URLs:
  - `https://github.com/org/repo.git`
  - `git@github.com:org/repo.git`

  Returns `{:error, :invalid_url}` for unparseable URLs.
  """
  @spec parse_remote_url(String.t()) :: {:ok, parsed_url()} | {:error, :invalid_url}
  def parse_remote_url(url) when is_binary(url) and byte_size(url) > 0 do
    cond do
      # SSH format: git@host:owner/repo.git
      String.starts_with?(url, "git@") ->
        parse_ssh_url(url)

      # HTTPS format: https://host/owner/repo.git
      String.starts_with?(url, "https://") or String.starts_with?(url, "http://") ->
        parse_https_url(url)

      true ->
        {:error, :invalid_url}
    end
  end

  def parse_remote_url(_), do: {:error, :invalid_url}

  defp parse_ssh_url(url) do
    # git@github.com:org/repo.git
    case Regex.run(~r/^git@([^:]+):(.+)$/, url) do
      [_, host, path] ->
        {owner, repo} = split_owner_repo(path)

        {:ok,
         %{
           protocol: :ssh,
           host: host,
           owner: owner,
           repo: repo
         }}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp parse_https_url(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        # Remove leading slash
        path = String.trim_leading(path, "/")
        {owner, repo} = split_owner_repo(path)

        {:ok,
         %{
           protocol: :https,
           host: host,
           owner: owner,
           repo: repo
         }}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp split_owner_repo(path) do
    # Remove .git suffix if present
    path = String.trim_trailing(path, ".git")

    # Split on last slash (handles nested groups like gitlab/group/subgroup/repo)
    case String.split(path, "/") |> Enum.reverse() do
      [repo | rest] ->
        owner = rest |> Enum.reverse() |> Enum.join("/")
        {owner, repo}

      _ ->
        {"", path}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # URL CONVERSION
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Convert any git URL to HTTPS format.

  SSH URLs are converted: `git@github.com:org/repo.git` → `https://github.com/org/repo.git`
  HTTPS URLs are returned unchanged.
  """
  @spec to_https_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def to_https_url(url) do
    case parse_remote_url(url) do
      {:ok, %{protocol: :https}} ->
        {:ok, url}

      {:ok, %{host: host, owner: owner, repo: repo}} ->
        {:ok, "https://#{host}/#{owner}/#{repo}.git"}

      error ->
        error
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CLONE COMMAND
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Generate a git clone command for the given context.

  ## Options

  - `:depth` - Clone depth (integer) or `:full` for full clone. Default: 1
  - `:dest` - Destination directory. Default: "/workspace"

  ## Example

      GitContext.clone_command(ctx, depth: 1)
      # => "git clone --depth=1 --branch=main https://... /workspace && cd /workspace && git checkout abc123"
  """
  @spec clone_command(t(), keyword()) :: String.t()
  def clone_command(ctx, opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)
    dest = Keyword.get(opts, :dest, "/workspace")

    url = ctx.url
    branch = ctx.branch
    sha = ctx.sha

    # Build clone command parts
    clone_parts = ["git clone"]

    clone_parts =
      if depth != :full and is_integer(depth) do
        clone_parts ++ ["--depth=#{depth}"]
      else
        clone_parts
      end

    clone_parts =
      if branch do
        clone_parts ++ ["--branch=#{branch}"]
      else
        clone_parts
      end

    clone_parts = clone_parts ++ [url, dest]

    clone_cmd = Enum.join(clone_parts, " ")

    # Add checkout command for specific SHA
    checkout_cmd = "cd #{dest} && git checkout #{sha}"

    "#{clone_cmd} && #{checkout_cmd}"
  end
end
